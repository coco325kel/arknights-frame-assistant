#Requires AutoHotkey v2.0
; 加载期错误（缺 include、include 路径写错、语法错误）OnError 抓不到，只能靠 #ErrorStdOut 送 stderr，
; 否则会弹窗阻塞自动化：见 docs/ahk_docs/lib/_ErrorStdOut.htm 与 docs/ahk_docs/lib/OnError.htm
#ErrorStdOut "UTF-8"
#Warn All, Off

; 冒烟测试骨架：
; 逐一 include 全部业务模块，确认所有 .ahk 只定义、零顶层副作用。
; 若某个模块在 include 时启动 GUI/定时器/写文件/弹窗等，本脚本会在 include 阶段暴露错误或非预期行为。
; 注意：这里不 include src/main.ahk，避免执行 App.Bootstrap()。

#Include ../../src/lib/base/logger.ahk
#Include ../../src/lib/base/version.ahk
#Include ../../src/lib/base/message_box.ahk
#Include ../../src/lib/base/single_instance.ahk
#Include ../../src/lib/base/token_protector.ahk
#Include ../../src/lib/base/hotkey_schema.ahk
#Include ../../src/lib/base/constants.ahk
#Include ../../src/lib/base/config.ahk
#Include ../../src/lib/base/theme.ahk
#Include ../../src/lib/base/eventbus.ahk
#Include ../../src/lib/base/i18n.ahk
#Include ../../src/lib/base/changelog_format.ahk
#Include ../../src/lib/base/metrics.ahk
#Include ../../src/lib/base/locales/zh_hans.ahk
#Include ../../src/lib/base/locales/ja_jp.ahk
#Include ../../src/lib/base/locales/ko_kr.ahk
#Include ../../src/lib/base/locales/en_us.ahk
#Include ../../src/lib/base/locales/zh_hant.ahk
#Include ../../src/lib/base/server_profile.ahk
#Include ../../src/lib/base/game_target.ahk
#Include ../../src/lib/base/game_audio_mute.ahk
#Include ../../src/lib/base/file_extractor.ahk
#Include ../../src/lib/base/timing.ahk
#Include ../../src/lib/base/window.ahk
#Include ../../src/lib/base/key_format.ahk
#Include ../../src/lib/base/tray.ahk
#Include ../../src/lib/base/version_utils.ahk
#Include ../../src/lib/base/touch_injection.ahk
#Include ../../src/lib/base/custom_hotkey_store.ahk
#Include ../../src/lib/core/game/game_client_registry.ahk
#Include ../../src/lib/core/audio/game_audio_controller.ahk
#Include ../../src/lib/core/diagnostics/log_exporter.ahk
#Include ../../src/lib/core/launch/app_context.ahk
#Include ../../src/lib/core/launch/game_auto_start.ahk
#Include ../../src/lib/core/hotkey/timing_service.ahk
#Include ../../src/lib/core/hotkey/game_keys.ahk
#Include ../../src/lib/core/hotkey/hotkey_actions.ahk
#Include ../../src/lib/core/hotkey/custom_script.ahk
#Include ../../src/lib/core/monitor/level_detector.ahk
#Include ../../src/lib/ui/key_bind.ahk
#Include ../../src/lib/core/hotkey/hotkey_service.ahk
#Include ../../src/lib/core/settings/hotkey_conflict_validator.ahk
#Include ../../src/lib/core/settings/settings_service.ahk
#Include ../../src/lib/core/updater/github_token_service.ahk
#Include ../../src/lib/core/updater/release_repository.ahk
#Include ../../src/lib/core/updater/version_checker.ahk
#Include ../../src/lib/core/updater/downloader.ahk
#Include ../../src/lib/core/updater/self_replacer.ahk
#Include ../../src/lib/core/updater/updater_manager.ahk
#Include ../../src/lib/ui/updater_ui.ahk
#Include ../../src/lib/core/launch/game_launcher.ahk
#Include ../../src/lib/ui/changelog_ui.ahk
#Include ../../src/lib/core/updater/changelog_checker.ahk
#Include ../../src/lib/ui/status_bar.ahk
#Include ../../src/lib/ui/gui.ahk
#Include ../../src/lib/ui/ui_shell.ahk
#Include ../../src/lib/ui/tray_controller.ahk
#Include ../../src/lib/ui/custom_key_editor.ahk
#Include ../../src/lib/core/monitor/game_monitor.ahk

OnError(SmokeFailure)
try {
    ; 骨架断言：关键类/函数应已定义（类名在 AHK v2 中可作为值访问）
    if !IsSet(Config) || !IsSet(Constants) || !IsSet(HotkeySchema) || !IsSet(I18n)
        ExitApp 1
    if !IsSet(GuiManager) || !IsSet(KeyBinder) || !IsSet(HotkeyService)
        ExitApp 1
    if !IsSet(StatusBarHints)
        ExitApp 1
    if !IsSet(GameMonitor) || !IsSet(VersionUtils) || !IsSet(KeyFormat) || !IsSet(HotkeyActions)
        ExitApp 1
    if !IsSet(SettingsService) || !IsSet(HotkeyConflictValidator)
        ExitApp 1
    if !IsSet(CustomHotkeyStore) || !IsSet(CustomScriptEngine) || !IsSet(CustomKeyEditor)
        ExitApp 1
    if !IsSet(ReleaseRepository) || !IsSet(GitHubTokenService) || !IsSet(ChangelogChecker)
        ExitApp 1
    if !IsSet(UiShell) || !IsSet(TrayController)
        ExitApp 1
    if !IsSet(GameAudioMute) || !IsSet(GameAudioController)
        ExitApp 1
    if GameAudioController.Initialized || GameAudioController.Timer
        ExitApp 1

    ; ---- 界面引擎规范化 ----
    if (Constants.NormalizeUiEngine("WEB") != "web")
        ExitApp 1
    if (Constants.NormalizeUiEngine("Classic") != "classic")
        ExitApp 1
    if (Constants.NormalizeUiEngine("") != "classic")
        ExitApp 1
    if (Constants.NormalizeUiEngine("bogus") != "classic")
        ExitApp 1

    ; ---- HotkeySchema 完整性校验 ----
    HotkeyService._BuildActionCallbacks()

    ; id 唯一 + 行为标志为布尔
    seenIds := Map()
    for item in HotkeySchema.Items {
        if seenIds.Has(item.id)
            ExitApp 1
        seenIds[item.id] := true
        if (item.guarded != true && item.guarded != false)
            ExitApp 1
        if (item.onUp != true && item.onUp != false)
            ExitApp 1
        if (item.noActivate != true && item.noActivate != false)
            ExitApp 1
        if item.HasOwnProp("repeatable") && (item.repeatable != true && item.repeatable != false)
            ExitApp 1
    }

    ; ActionBindings 与 Schema 双向覆盖
    for id, _ in HotkeyService.ActionBindings {
        if (HotkeySchema.GetItem(id) = "")
            ExitApp 1
    }
    for item in HotkeySchema.Items {
        if !HotkeyService.ActionBindings.Has(item.id)
            ExitApp 1
    }

    ; ActionCallbacks 数量与绑定一致，且行为标志与 Schema 一致
    if (HotkeyService.ActionCallbacks.Count != HotkeyService.ActionBindings.Count)
        ExitApp 1
    for item in HotkeySchema.Items {
        profile := HotkeyService.ActionCallbacks[item.id]
        if (profile.HasOwnProp("Guarded") != item.guarded)
            ExitApp 1
        if (profile.HasOwnProp("OnUp") != item.onUp)
            ExitApp 1
        if (profile.HasOwnProp("NoActivate") != item.noActivate)
            ExitApp 1
        if (profile.HasOwnProp("Repeatable") != (item.HasOwnProp("repeatable") && item.repeatable))
            ExitApp 1
    }

    ; 分组 Map 与 Schema 一致
    for group, constantsMap in Map("combat", Constants.CombatHotkeys, "quick", Constants.QuickHotkeys, "strongHold", Constants.StrongHoldHotkeys) {
        schemaMap := HotkeySchema.GetGroupMap(group)
        if (schemaMap.Count != constantsMap.Count)
            ExitApp 1
        for id, _ in schemaMap {
            if !constantsMap.Has(id)
                ExitApp 1
        }
    }

    ; 探针：确认没有顶层副作用把 Config.IniFile 提前初始化（应仍为空）
    if (Config.IniFile != "" || Theme._Ready || Theme._SubclassPtr)
        ExitApp 1

    SmokeAudioBatch()
    FileAppend("PASS: smoke contracts and no initialization`n", "*", "UTF-8")
    ExitApp 0
} catch as err
    SmokeFailure(err)

SmokeFailure(err, *) {
    message := "FAIL: " err.Message " (line " err.Line ")`n"
    try FileAppend(message, "**", "UTF-8")
    try FileAppend(message, A_Temp "\AFA-smoke-test-error.txt", "UTF-8")
    ExitApp 1
}

SmokeAudioBatch() {
    SmokeAudioHotkeys.ActionGameVolumeUp("")
    if SmokeAudioHotkeys.Delta != 0.1
        throw Error("volume-up hotkey must request 10 percentage points")
    SmokeAudioHotkeys.ActionGameVolumeDown("")
    if SmokeAudioHotkeys.Delta != -0.1
        throw Error("volume-down hotkey must request 10 percentage points")
    capture := GameAudioMute.GetOwnPropDesc("Capture")
    release := GameAudioMute.GetOwnPropDesc("ReleaseSnapshot")
    clients := GameClientRegistry.GetOwnPropDesc("GetClients")
    scans := 0
    session := SmokeAudioSession()
    snapshot := {sessions: [session], devices: Map("device", true), defaultDevice: "device", total: 1, failed: 0, message: ""}
    CaptureBatch(*) {
        scans++
        return snapshot
    }
    try {
        GameAudioMute.DefineProp("Capture", {Call: CaptureBatch})
        GameAudioMute.DefineProp("ReleaseSnapshot", {Call: (*) => 0})
        GameClientRegistry.DefineProp("GetClients", {Call: (*) => [{pid: 1}]})
        SmokeAudioController.States := Map()
        SmokeAudioController.Actions := []
        SmokeAudioController.Notices := []
        SmokeAudioController.AutoEnabled := false
        SmokeAudioController.Initialized := true
        for delta in [0.1, 0.1, -0.1, -0.1]
            SmokeAudioController.Actions.Push({pid: 1, kind: "volume", delta: delta, created: "created", callback: 0})
        SmokeAudioController.Tick()
        if scans != 1
            throw Error("four queued volume actions must use one snapshot; scans=" scans)
        if Abs(session.level - 0.4) > 0.0001 || SmokeAudioController.Actions.Length
            throw Error("queued volume actions must remain ordered and complete")
        session.level := 1
        for delta in [0.1, -0.1]
            SmokeAudioController.Actions.Push({pid: 1, kind: "volume", delta: delta, created: "created", callback: 0})
        SmokeAudioController.Tick()
        if Abs(session.level - 0.9) > 0.0001
            throw Error("opposite actions at the upper boundary must not cancel")
        session.level := 0
        for delta in [-0.1, 0.1]
            SmokeAudioController.Actions.Push({pid: 1, kind: "volume", delta: delta, created: "created", callback: 0})
        SmokeAudioController.Tick()
        if Abs(session.level - 0.1) > 0.0001
            throw Error("opposite actions at the lower boundary must not cancel")
        if SmokeAudioController.BurstUntil
            throw Error("successful volume actions must not start device-rescan bursts")
        state := SmokeAudioController.States[1]
        state.manual := true
        SmokeAudioController.Reconcile(1, state, snapshot, true)
        session.failVolume := true
        result := SmokeAudioController._Execute({pid: 1, kind: "volume", delta: 0.1, created: "created"}, snapshot)
        if state.manual || !session.muted || result.volumeFailed != 1
            throw Error("failed Up must clear manual intent but keep the session muted")
        session.failVolume := false
        SmokeAudioController._Execute({pid: 1, kind: "volume", delta: -0.1, created: "created"}, snapshot)
        if session.muted || Abs(session.level) > 0.0001
            throw Error("Down must finish the pending Up at the latest target")
        SmokeAudioController.AutoEnabled := true
        SmokeAudioController._Execute({pid: 1, kind: "volume", delta: 0.1, created: "created"}, snapshot)
        if !session.muted
            throw Error("background auto-mute must survive volume Up")
        SmokeAudioController.AutoEnabled := false
        before := session.level
        result := SmokeAudioController._Execute({pid: 1, kind: "volume", delta: 0.1, created: "old"}, snapshot)
        if result.success || session.level != before
            throw Error("stale queued identity must not change a session")
        SmokeAudioController.States := Map()
        before := scans
        SmokeAudioController.Tick()
        if scans != before
            throw Error("idle controller with no mute/volume/restore intent must not scan audio")
        GameClientRegistry.DefineProp("GetClients", {Call: (*) => [{pid: 1}, {pid: 2}]})
        SmokeAudioController.DisappearAfterBatch := true
        SmokeAudioController.Actions.Push({pid: 1, kind: "volume", delta: 0.1, created: "created", callback: 0})
        completed := []
        SmokeAudioController._SyncClients(completed)
        if completed.Length != 1 || completed[1].result.success || scans != before
            throw Error("disappearing action with another idle PID must report failure without scanning")
        FileAppend("PASS: audio batches, ordered 10-point steps and boundaries`n", "*", "UTF-8")
    } finally {
        GameAudioMute.DefineProp("Capture", capture)
        GameAudioMute.DefineProp("ReleaseSnapshot", release)
        GameClientRegistry.DefineProp("GetClients", clients)
    }
}

class SmokeAudioHotkeys extends HotkeyActions {
    static Delta := 0
    static _QueueGameAudio(kind, delta) => this.Delta := delta
}

class SmokeAudioController extends GameAudioController {
    static GonePid := 0
    static DisappearAfterBatch := false
    static Identity(pid) => pid = this.GonePid ? "" : "created"
    static GetState(pid, expectedCreated := "") {
        created := this.Identity(pid)
        if StrLen(created) = 0 || (StrLen(expectedCreated) > 0 && expectedCreated != created)
            throw Error("stale identity")
        state := this.StateFor(this.States, pid, created)
        if this.DisappearAfterBatch && StrLen(expectedCreated) > 0
            this.GonePid := pid
        return state
    }
    static UpdateTargets(targets) {
    }
    static _Schedule() {
    }
}

class SmokeAudioSession {
    device := "device", id := "session", instance := "instance", pid := 1, status := 1
    level := 0.4, muted := false, failVolume := false
    GetVolume() => this.level
    SetVolume(value) {
        if this.failVolume
            throw Error("unavailable session")
        this.level := value
    }
    GetMute() => this.muted
    SetMute(value) => this.muted := value
}
