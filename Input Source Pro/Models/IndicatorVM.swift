import AppKit
import AXSwift
import Combine
import CombineExt
import os

@MainActor
final class IndicatorVM: ObservableObject {
    private var cancelBag = CancelBag()
    private lazy var shortcutTriggerManager = ShortcutTriggerManager(preferencesVM: preferencesVM)

    let applicationVM: ApplicationVM
    let preferencesVM: PreferencesVM
    let inputSourceVM: InputSourceVM
    let permissionsVM: PermissionsVM
    let punctuationService: PunctuationService

    let logger = ISPLogger(category: String(describing: IndicatorVM.self))

    /// The function-key mode currently enforced by the app (per-app rule, default,
    /// or shortcut override). Published so the Function Keys settings chip can mirror
    /// the live mode the indicator shows, instead of the stored global default.
    @Published private(set) var currentFKeyMode: FKeyMode?

    /// Fires when the user toggles the function-key mode via the shortcut, so the
    /// indicator can show the new mode the same way it shows input-source changes.
    let functionKeyModeChangeSubject = PassthroughSubject<FKeyMode, Never>()

    @Published
    private(set) var state: State

    var actionSubject = PassthroughSubject<Action, Never>()

    var refreshShortcutSubject = PassthroughSubject<Void, Never>()

    private var stableUserLayoutCacheWork: DispatchWorkItem?
    private let stableUserLayoutCacheDelay: TimeInterval = 1.5

    private var lastAppliedLayoutIdByBundle: [String: String] = [:]
    private var lastAppliedAtByBundle: [String: Date] = [:]
    private let leaveStealGuardWindow: TimeInterval = 1.25

    private(set) lazy var activateEventPublisher = Publishers.MergeMany([
        longMouseDownPublisher(),
        stateChangesPublisher(),
        functionKeyModeChangesPublisher(),
    ])
    .share()

    private(set) lazy var screenIsLockedPublisher = Publishers.MergeMany([
        DistributedNotificationCenter.default()
            .publisher(for: Notification.Name(rawValue: "com.apple.screenIsLocked"))
            .mapTo(true),

        DistributedNotificationCenter.default()
            .publisher(for: NSWorkspace.willSleepNotification)
            .mapTo(true),

        DistributedNotificationCenter.default()
            .publisher(for: Notification.Name(rawValue: "com.apple.screenIsUnlocked"))
            .mapTo(false),

        DistributedNotificationCenter.default()
            .publisher(for: NSWorkspace.didWakeNotification)
            .mapTo(false),
    ])
    .receive(on: DispatchQueue.main)
    .prepend(false)
    .removeDuplicates()
    .share()

    init(
        permissionsVM: PermissionsVM,
        preferencesVM: PreferencesVM,
        applicationVM: ApplicationVM,
        inputSourceVM: InputSourceVM
    ) {
        self.permissionsVM = permissionsVM
        self.preferencesVM = preferencesVM
        self.applicationVM = applicationVM
        self.inputSourceVM = inputSourceVM
        self.punctuationService = PunctuationService(preferencesVM: preferencesVM)
        state = .from(
            preferencesVM: preferencesVM,
            inputSourceChangeReason: .system,
            applicationVM.appKind,
            InputSource.getCurrentInputSource()
        )

        clearAppKeyboardCacheIfNeed()
        watchState()
        watchPunctuationRules()
        watchFunctionKeyMode()
    }

    private func clearAppKeyboardCacheIfNeed() {
        preferencesVM.$preferences
            .map(\.isRestorePreviouslyUsedInputSource)
            .removeDuplicates()
            .dropFirst()
            .filter { $0 == false }
            .sink { [weak self] _ in
                self?.preferencesVM.clearKeyboardCache()
                ISPFileLog.event("cache-clear", "restore-previously-used turned off", includeSnapshot: false)
            }
            .store(in: cancelBag)
    }

    private func watchPunctuationRules() {
        applicationVM.$appKind
            .compactMap { $0 }
            .sink { [weak self] appKind in
                guard let self = self else { return }
                
                let app = appKind.getApp()
                if self.punctuationService.shouldEnableForApp(app) {
                    self.logger.debug { "Enabling English punctuation for app: \(app.localizedName ?? app.bundleIdentifier ?? "Unknown")" }
                    self.punctuationService.enable()
                } else {
                    self.punctuationService.disable()
                }
            }
            .store(in: cancelBag)
    }

    private func watchFunctionKeyMode() {
        applicationVM.$appKind
            .compactMap { $0 }
            .sink { [weak self] appKind in
                self?.applyFunctionKeyMode(for: appKind)
            }
            .store(in: cancelBag)

        preferencesVM.$preferences
            .map(\.isFunctionKeysEnabled)
            .removeDuplicates()
            .sink { [weak self] _ in
                guard let self = self,
                      let appKind = self.applicationVM.appKind
                else { return }

                self.applyFunctionKeyMode(for: appKind)
            }
            .store(in: cancelBag)
    }

    private func applyFunctionKeyMode(for appKind: AppKind) {
        let desiredMode = preferencesVM.functionKeyMode(for: appKind)

        guard desiredMode != currentFKeyMode else { return }

        do {
            try FKeyManager.setCurrentFKeyMode(desiredMode)
            currentFKeyMode = desiredMode
        } catch {
            logger.debug { "Failed to set function key mode: \(error.localizedDescription)" }
        }
    }
}

extension IndicatorVM {
    enum InputSourceChangeReason {
        case noChanges, system, shortcut, appSpecified(PreferencesVM.AppAutoSwitchKeyboardStatus)
    }

    @MainActor
    struct State {
        let appKind: AppKind?
        let inputSource: InputSource
        let inputSourceChangeReason: InputSourceChangeReason

        func isSame(with other: State) -> Bool {
            return State.isSame(self, other)
        }

        static func isSame(_ lhs: IndicatorVM.State, _ rhs: IndicatorVM.State) -> Bool {
            guard let appKind1 = lhs.appKind, let appKind2 = rhs.appKind
            else { return lhs.appKind == nil && rhs.appKind == nil }

            guard appKind1.isSameAppOrWebsite(with: appKind2, detectAddressBar: true)
            else { return false }

            guard lhs.inputSource.persistentIdentifier == rhs.inputSource.persistentIdentifier
            else { return false }

            return true
        }

        static func from(
            preferencesVM _: PreferencesVM,
            inputSourceChangeReason: InputSourceChangeReason,
            _ appKind: AppKind?,
            _ inputSource: InputSource
        ) -> State {
            return .init(
                appKind: appKind,
                inputSource: inputSource,
                inputSourceChangeReason: inputSourceChangeReason
            )
        }
    }

    enum Action {
        case start
        case appChanged(AppKind)
        case switchInputSourceByShortcut(InputSource)
        case inputSourceChanged(InputSource)
    }

    func send(_ action: Action) {
        actionSubject.send(action)
    }

    func refreshShortcut() {
        refreshShortcutSubject.send(())
    }

    func watchState() {
        actionSubject
            .scan(state) { [weak self] state, action -> State in
                guard let preferencesVM = self?.preferencesVM,
                      let inputSourceVM = self?.inputSourceVM
                else { return state }

                @MainActor
                func updateState(
                    appKind: AppKind?,
                    inputSource: InputSource,
                    inputSourceChangeReason: InputSourceChangeReason,
                    shouldCache: Bool
                ) -> State {
                    if shouldCache, let appKind = appKind {
                        preferencesVM.cacheKeyboardFor(appKind, keyboard: inputSource)
                    }

                    return .from(
                        preferencesVM: preferencesVM,
                        inputSourceChangeReason: inputSourceChangeReason,
                        appKind,
                        inputSource
                    )
                }

                switch action {
                case .start:
                    return state
                case let .appChanged(appKind):
                    self?.stableUserLayoutCacheWork?.cancel()

                    if let previous = state.appKind,
                       let prevId = previous.getApp().bundleIdentifier,
                       prevId != appKind.getApp().bundleIdentifier,
                       !SystemChrome.isLaunchpadRelated(prevId)
                    {
                        let leavingLayout = self?.layoutForLeave(previous) ?? InputSource.getCurrentInputSource()
                        preferencesVM.rememberKeyboardOnLeave(for: previous, keyboard: leavingLayout)
                    }

                    if let restored = self?.applicationVM.consumeLaunchpadLayoutRestore(for: appKind) {
                        ISPFileLog.event(
                            "switch",
                            "app=\(appKind.getApp().bundleIdentifier ?? "?") via=launchpad-restore → \(restored.persistentIdentifier)"
                        )
                        inputSourceVM.select(inputSource: restored, app: appKind.getApp())
                        self?.noteAppliedLayout(appKind, restored)
                        return updateState(
                            appKind: appKind,
                            inputSource: restored,
                            inputSourceChangeReason: .appSpecified(.cached(restored)),
                            shouldCache: false
                        )
                    }

                    if let status = preferencesVM.getAppAutoSwitchKeyboard(appKind) {
                        // The target keyboard is already active in macOS: skip the
                        // redundant TIS select (and CJKV fix) so nothing "switches",
                        // and mark the reason as .noChanges so the indicator won't
                        // announce it. Compare against the live system source rather
                        // than the reducer's optimistic `state.inputSource`, so a
                        // failed or delayed select is retried instead of skipped.
                        let liveInputSource = InputSource.getCurrentInputSource()
                        if status.inputSource.persistentIdentifier == liveInputSource.persistentIdentifier {
                            return updateState(
                                appKind: appKind,
                                inputSource: liveInputSource,
                                inputSourceChangeReason: .noChanges,
                                shouldCache: false
                            )
                        }

                        let via: String = {
                            switch status {
                            case .cached: return "cached"
                            case .specified: return "specified"
                            }
                        }()
                        let disk = preferencesVM.appKeyboardCache.retrieve(appKind)?.persistentIdentifier ?? "nil"
                        let current = InputSource.getCurrentInputSource().persistentIdentifier
                        ISPFileLog.event(
                            "switch",
                            "app=\(appKind.getApp().bundleIdentifier ?? "?") via=\(via) → \(status.inputSource.persistentIdentifier) | current=\(current) disk=\(disk)"
                        )
                        inputSourceVM.select(inputSource: status.inputSource, app: appKind.getApp())
                        self?.noteAppliedLayout(appKind, status.inputSource)

                        return updateState(
                            appKind: appKind,
                            inputSource: status.inputSource,
                            inputSourceChangeReason: .appSpecified(status),
                            shouldCache: false
                        )
                    } else {
                        ISPFileLog.event(
                            "switch-skip",
                            "app=\(appKind.getApp().bundleIdentifier ?? "?") no rule/cache"
                        )
                        return updateState(
                            appKind: appKind,
                            inputSource: state.inputSource,
                            inputSourceChangeReason: .noChanges,
                            shouldCache: false
                        )
                    }
                case let .inputSourceChanged(inputSource):
                    guard inputSource.persistentIdentifier != state.inputSource.persistentIdentifier else { return state }

                    ISPFileLog.event(
                        "tis-system",
                        "\(state.inputSource.persistentIdentifier) → \(inputSource.persistentIdentifier) app=\(state.appKind?.getApp().bundleIdentifier ?? "nil")"
                    )

                    if let appKind = state.appKind,
                       let forced = preferencesVM.forcedKeyboard(for: appKind),
                       forced.persistentIdentifier != inputSource.persistentIdentifier
                    {
                        ISPFileLog.event(
                            "forced-repin",
                            "\(appKind.getApp().bundleIdentifier ?? "?") \(inputSource.persistentIdentifier) → \(forced.persistentIdentifier)"
                        )
                        inputSourceVM.select(inputSource: forced, app: appKind.getApp())
                        self?.noteAppliedLayout(appKind, forced)
                        return updateState(
                            appKind: appKind,
                            inputSource: forced,
                            inputSourceChangeReason: .appSpecified(.specified(forced)),
                            shouldCache: false
                        )
                    }

                    let newState = updateState(
                        appKind: state.appKind,
                        inputSource: inputSource,
                        inputSourceChangeReason: .system,
                        shouldCache: false
                    )
                    self?.scheduleStableUserLayoutCache(appKind: state.appKind, inputSource: inputSource)
                    return newState
                case let .switchInputSourceByShortcut(inputSource):
                    inputSourceVM.select(inputSource: inputSource, app: state.appKind?.getApp())
                    if let appKind = state.appKind {
                        self?.noteAppliedLayout(appKind, inputSource)
                    }

                    return updateState(
                        appKind: state.appKind,
                        inputSource: inputSource,
                        inputSourceChangeReason: .shortcut,
                        shouldCache: true
                    )
                }
            }
            .removeDuplicates(by: { $0.isSame(with: $1) })
            .assign(to: &$state)

        applicationVM.$appKind
            .compactMap { $0 }
            .sink(receiveValue: { [weak self] in self?.send(.appChanged($0)) })
            .store(in: cancelBag)

        inputSourceVM.inputSourceChangesPublisher
            .sink(receiveValue: { [weak self] in self?.send(.inputSourceChanged($0)) })
            .store(in: cancelBag)

        refreshShortcutSubject
            .sink { [weak self] _ in
                guard let self = self else { return }

                self.shortcutTriggerManager.updateBindings(self.shortcutBindings())
            }
            .store(in: cancelBag)

        refreshShortcut()
        send(.start)
    }

    private func noteAppliedLayout(_ appKind: AppKind, _ inputSource: InputSource) {
        guard let bundleId = appKind.getApp().bundleIdentifier else { return }
        lastAppliedLayoutIdByBundle[bundleId] = inputSource.persistentIdentifier
        lastAppliedAtByBundle[bundleId] = Date()
    }

    private func layoutForLeave(_ appKind: AppKind) -> InputSource {
        let current = InputSource.getCurrentInputSource()
        let bundleId = appKind.getApp().bundleIdentifier ?? "?"
        let disk = preferencesVM.appKeyboardCache.retrieve(appKind)?.persistentIdentifier ?? "nil"

        guard let bundleKey = appKind.getApp().bundleIdentifier,
              let appliedId = lastAppliedLayoutIdByBundle[bundleKey],
              let appliedAt = lastAppliedAtByBundle[bundleKey],
              let applied = InputSource.resolvePersistedIdentifier(appliedId)
        else {
            ISPFileLog.event(
                "leave-pick",
                "\(bundleId) use=current \(current.persistentIdentifier) disk=\(disk)",
                includeSnapshot: false
            )
            return current
        }

        let sinceApply = Date().timeIntervalSince(appliedAt)
        if sinceApply <= leaveStealGuardWindow,
           current.persistentIdentifier != applied.persistentIdentifier
        {
            ISPFileLog.event(
                "leave-pick",
                "\(bundleId) use=applied \(applied.persistentIdentifier) (guard \(String(format: "%.2f", sinceApply))s) current=\(current.persistentIdentifier) disk=\(disk)",
                includeSnapshot: false
            )
            return applied
        }

        ISPFileLog.event(
            "leave-pick",
            "\(bundleId) use=current \(current.persistentIdentifier) applied=\(applied.persistentIdentifier) sinceApply=\(String(format: "%.2f", sinceApply)) disk=\(disk)",
            includeSnapshot: false
        )
        return current
    }

    private func scheduleStableUserLayoutCache(appKind: AppKind?, inputSource: InputSource) {
        stableUserLayoutCacheWork?.cancel()

        guard let appKind,
              !SystemChrome.shouldNeverCache(appKind.getApp().bundleIdentifier),
              preferencesVM.appNeedCacheKeyboard(appKind)
        else { return }

        let tokenBundle = appKind.getApp().bundleIdentifier
        let tokenLayout = inputSource.persistentIdentifier
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            guard self.state.appKind?.getApp().bundleIdentifier == tokenBundle,
                  self.state.inputSource.persistentIdentifier == tokenLayout,
                  !LaunchpadOverlayDetector.isLaunchpadVisible()
            else { return }

            self.preferencesVM.cacheKeyboardFor(appKind, keyboard: inputSource)
            ISPFileLog.event(
                "cache-stable",
                "\(tokenBundle ?? "?") → \(tokenLayout)",
                includeSnapshot: false
            )
        }
        stableUserLayoutCacheWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + stableUserLayoutCacheDelay, execute: work)
    }

    private func shortcutBindings() -> [ShortcutBinding] {
        var bindings: [ShortcutBinding] = []

        for inputSource in InputSource.sources {
            let mode = preferencesVM.shortcutMode(for: inputSource)
            let trigger = preferencesVM.singleModifierTrigger(for: inputSource)
            let modifierCombo = preferencesVM.modifierCombo(for: inputSource)

            bindings.append(
                ShortcutBinding(
                    id: inputSource.persistentIdentifier,
                    mode: mode,
                    modifierCombo: modifierCombo,
                    singleModifierTrigger: trigger,
                    onTrigger: { [weak self] in
                        self?.send(.switchInputSourceByShortcut(inputSource))
                    }
                )
            )
        }

        for group in preferencesVM.getHotKeyGroups() {
            guard let id = group.id else { continue }

            let mode = preferencesVM.shortcutMode(for: group)
            let trigger = preferencesVM.singleModifierTrigger(for: group)
            let modifierCombo = preferencesVM.modifierCombo(for: group)

            bindings.append(
                ShortcutBinding(
                    id: id,
                    mode: mode,
                    modifierCombo: modifierCombo,
                    singleModifierTrigger: trigger,
                    onTrigger: { [weak self] in
                        self?.triggerHotKeyGroup(group)
                    }
                )
            )
        }

        bindings.append(
            ShortcutBinding(
                id: PreferencesVM.functionKeysToggleShortcutId,
                mode: preferencesVM.functionKeysToggleMode(),
                modifierCombo: preferencesVM.functionKeysToggleCombo(),
                singleModifierTrigger: preferencesVM.functionKeysToggleTrigger(),
                onTrigger: { [weak self] in
                    self?.toggleFunctionKeyMode()
                }
            )
        )

        return bindings
    }

    private func toggleFunctionKeyMode() {
        let current = currentFKeyMode
            ?? (try? FKeyManager.getCurrentFKeyMode().get())
            ?? preferencesVM.preferences.functionKeyMode
        let toggled: FKeyMode = current == .functionKeys ? .mediaKeys : .functionKeys

        // Persist as the new global default. This keeps the change for apps without a
        // per-app rule and keeps the General → "Default Function Keys" toggle in sync.
        // The synchronous `watchFunctionKeyMode` sink may re-apply a per-app rule here.
        preferencesVM.update { $0.functionKeyMode = toggled }

        // Force the live system mode afterwards so the toggle takes effect immediately,
        // even when the frontmost app has a per-app Function Keys rule. The rule
        // re-asserts on the next app switch.
        do {
            try FKeyManager.setCurrentFKeyMode(toggled)
            currentFKeyMode = toggled
            functionKeyModeChangeSubject.send(toggled)
        } catch {
            logger.debug { "Failed to toggle function key mode: \(error.localizedDescription)" }
        }
    }

    private func triggerHotKeyGroup(_ group: HotKeyGroup) {
        let inputSources = group.inputSources
        guard inputSources.count > 0 else { return }

        let currentInputSource = InputSource.getCurrentInputSource()
        let nextIndex = (
            (inputSources.firstIndex {
                currentInputSource.persistentIdentifier == $0.persistentIdentifier
            } ?? -1) + 1
        ) % inputSources.count

        send(.switchInputSourceByShortcut(inputSources[nextIndex]))
    }
}
