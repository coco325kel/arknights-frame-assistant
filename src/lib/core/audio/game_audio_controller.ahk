class GameAudioController {
    static States := Map()
    static Initialized := false
    static Busy := false
    static Timer := 0
    static WakeTimer := 0
    static WakeQueued := false
    static BurstUntil := 0
    static Interval := 0
    static AutoEnabled := true
    static Degraded := true
    static TargetSignature := ""
    static Warnings := Map()
    static Notifications := 0
    static Actions := []
    static Notices := []
    static SettingsPending := false
    static SyncPending := false
    static StopRequested := false
    static RestartRequested := false
    static SyncCallback := 0
    static Generation := 0

    static ShouldMute(manual, background, enabled) => manual || (enabled && background)
    static Identity(pid) {
        handle := DllCall("OpenProcess", "UInt", 0x1000, "Int", false, "UInt", pid, "Ptr")
        if !handle
            return ""
        times := Buffer(32)
        try {
            if !DllCall("GetProcessTimes", "Ptr", handle, "Ptr", times.Ptr, "Ptr", times.Ptr + 8,
                "Ptr", times.Ptr + 16, "Ptr", times.Ptr + 24)
                return ""
            return Format("{:016X}", NumGet(times, 0, "UInt64"))
        } finally DllCall("CloseHandle", "Ptr", handle)
    }
    static StateFor(states, pid, created) {
        if !states.Has(pid) || states[pid].created != created
            states[pid] := {pid: pid, created: created, manual: false, sessions: Map(), deferred: Map(), unmutePending: false,
                volumeTarget: "", volumeDelta: 0, volumeQueued: false, volumeApplied: Map(), volumeUnmute: false}
        return states[pid]
    }
    static GetState(pid, expectedCreated := "") {
        created := this.Identity(pid)
        if StrLen(created) = 0 || (StrLen(expectedCreated) > 0 && created != expectedCreated)
            || StrLower(ProcessGetName(pid)) != StrLower(ServerProfile.ExeName)
            throw Error("无法确认游戏进程身份")
        return this.StateFor(this.States, pid, created)
    }
    static Key(session) {
        return StrLen(session.device) ":" session.device StrLen(session.id) ":" session.id session.instance
    }
    static RequestUnmute(state) {
        state.unmutePending := true
        for _, record in state.sessions
            record.muted := false
        for _, record in state.deferred
            record.muted := false
    }
    static ReferenceVolume(pid, snapshot) {
        result := {volume: "", failed: 0, message: ""}
        defaultDevice := snapshot.defaultDevice
        Loop 3 {
            priority := A_Index
            for session in snapshot.sessions {
                if session.pid != pid || session.status = 2
                    continue
                rank := session.status = 1 ? (session.device = defaultDevice ? 1 : 2) : 3
                if rank != priority
                    continue
                try {
                    result.volume := session.GetVolume()
                    result.failed := 0
                    return result
                } catch Error as e {
                    result.failed++, result.message := e.Message
                }
            }
        }
        return result
    }
    static AdjustSnapshot(pid, state, snapshot, delta) {
        reference := this.ReferenceVolume(pid, snapshot)
        if IsNumber(reference.volume) {
            state.volumeTarget := Min(1, Max(0, reference.volume + state.volumeDelta + delta))
            state.volumeDelta := 0, state.volumeQueued := false
        } else if IsNumber(state.volumeTarget) {
            state.volumeTarget := Min(1, Max(0, state.volumeTarget + delta))
        } else {
            state.volumeDelta += delta, state.volumeQueued := true
        }
        state.volumeApplied.Clear()
        if delta > 0 {
            ; 手动意图立即清除；每个会话写入最新目标音量后才能恢复出声。
            state.manual := false
            state.volumeUnmute := true
            this.RequestUnmute(state)
        }
        background := this.AutoEnabled && GameClientRegistry.ForegroundPid != pid
        result := this.Reconcile(pid, state, snapshot, state.manual || background)
        result.background := background
        return result
    }
    static Reconcile(pid, state, snapshot, shouldMute, applyVolume := true) {
        result := {success: false, found: 0, failed: snapshot.failed,
            message: snapshot.message, pending: 0, muteFailed: 0,
            volume: state.volumeTarget, volumeFailed: 0, volumePending: 0,
            manual: state.manual, background: this.AutoEnabled && GameClientRegistry.ForegroundPid != pid}
        if applyVolume && state.volumeQueued {
            reference := this.ReferenceVolume(pid, snapshot)
            if IsNumber(reference.volume) {
                state.volumeTarget := Min(1, Max(0, reference.volume + state.volumeDelta))
                state.volumeDelta := 0, state.volumeQueued := false
            } else {
                result.volumeFailed := reference.failed
                if reference.failed
                    result.message := reference.message
            }
        }
        result.volume := state.volumeTarget
        present := Map(), expired := Map()
        for session in snapshot.sessions {
            if session.pid = pid {
                if session.status = 2
                    expired[this.Key(session)] := true
                else
                    present[this.Key(session)] := true
            }
        }
        if applyVolume && state.manual && GameClientRegistry.ForegroundPid = pid && !state.volumeUnmute {
            for session in snapshot.sessions {
                key := this.Key(session)
                if session.pid != pid || session.status = 2 || !state.sessions.Has(key)
                    continue
                record := state.sessions[key]
                if !record.HasOwnProp("manualEnforced") || !record.manualEnforced
                    continue
                try {
                    if !session.GetMute() {
                        state.manual := false
                        record.muted := false
                        shouldMute := false
                        break
                    }
                } catch Error {
                    record.manualEnforced := false
                }
            }
        }
        for session in snapshot.sessions {
            if session.pid != pid
                continue
            key := this.Key(session)
            if session.status = 2
                continue
            result.found++
            volumeReady := !(applyVolume && state.volumeQueued)
            if applyVolume && IsNumber(state.volumeTarget) && !state.volumeApplied.Has(key) {
                try {
                    session.SetVolume(state.volumeTarget)
                    state.volumeApplied[key] := session.device
                } catch Error as e {
                    volumeReady := false
                    result.volumeFailed++, result.volumePending++, result.message := e.Message
                }
            }
            ; 旧实例已消失时，新实例沿用原始静音值，但不沿用外部改动判定标记。
            if !state.sessions.Has(key) {
                for records in [state.sessions, state.deferred] {
                    previous := ""
                    for oldKey, record in records {
                        if record.device = session.device && record.id = session.id && (oldKey = key || !present.Has(oldKey)) {
                            previous := oldKey
                            break
                        }
                    }
                    if StrLen(previous) > 0 {
                        record := records[previous]
                        records.Delete(previous)
                        record.instance := session.instance
                        record.manualEnforced := false
                        state.sessions[key] := record
                        break
                    }
                }
            }
            try {
                current := session.GetMute()
                if shouldMute {
                    if !state.sessions.Has(key)
                        state.sessions[key] := {device: session.device, id: session.id, instance: session.instance,
                            muted: state.unmutePending ? false : current, manualEnforced: false}
                    target := true
                } else if state.sessions.Has(key) {
                    target := state.sessions[key].muted
                } else if state.unmutePending {
                    target := false
                } else {
                    continue
                }
                if current != target {
                    if !target && state.volumeUnmute && !volumeReady {
                        continue
                    }
                    session.SetMute(target)
                    GameAudioMute.WriteCount++
                }
                if state.sessions.Has(key)
                    state.sessions[key].manualEnforced := shouldMute && state.manual && GameClientRegistry.ForegroundPid = pid
                if !shouldMute && state.sessions.Has(key)
                    state.sessions.Delete(key)
            } catch Error as e {
                if state.sessions.Has(key)
                    state.sessions[key].manualEnforced := false
                result.failed++, result.muteFailed++, result.message := e.Message
            }
        }
        obsolete := []
        for key, record in state.sessions {
            if !present.Has(key)
                record.manualEnforced := false
            ; 断开设备或枚举不完整时保留恢复记录。
            if expired.Has(key) || (!present.Has(key) && snapshot.devices.Has(record.device) && snapshot.devices[record.device])
                obsolete.Push(key)
        }
        for key in obsolete {
            state.deferred[key] := state.sessions[key]
            state.sessions.Delete(key)
        }
        obsolete := []
        for key, device in state.volumeApplied {
            if expired.Has(key) || (!present.Has(key) && snapshot.devices.Has(device) && snapshot.devices[device])
                obsolete.Push(key)
        }
        for key in obsolete
            state.volumeApplied.Delete(key)
        if applyVolume && (state.volumeQueued || (IsNumber(state.volumeTarget) && result.found = 0))
            result.volumePending++
        result.failed += result.volumeFailed
        if applyVolume && state.volumeUnmute && result.found > 0 && !state.volumeQueued
            && result.failed = 0 && !state.sessions.Count && !state.deferred.Count
            state.volumeUnmute := false
        if state.unmutePending && result.found > 0 && result.failed = 0
            state.unmutePending := false
        result.pending := shouldMute ? (result.found = 0 ? 1 : 0) : state.sessions.Count + state.deferred.Count
        result.success := result.failed = 0 && (shouldMute || result.pending = 0)
        result.manual := state.manual
        if !shouldMute && result.pending && StrLen(result.message) = 0
            result.message := "部分设备或会话尚未重新出现，已保留恢复记录，稍后重试"
        return result
    }
    static RefreshSettings(*) {
        if !this.Initialized
            return
        this.SettingsPending := true
        this.RequestSync()
    }
    static Init() {
        if this.StopRequested {
            this.RestartRequested := true
            return
        }
        if this.Initialized
            return
        Thread "NoTimers"
        try {
            this.Generation++
            this.Interval := 0
            this.WakeQueued := false
            this.SyncPending := false
            this.Actions := []
            this.Notices := []
            this.TargetSignature := "?"
            this.BurstUntil := 0
            this.Timer := this.Tick.Bind(this)
            this.WakeTimer := this._Wake.Bind(this)
            this.SyncCallback := this.RequestSync.Bind(this)
            this.LoadPending()
            EventBus.Subscribe("ForegroundClientChanged", this.SyncCallback)
            EventBus.Subscribe("GameClientsChanged", this.SyncCallback)
            this.Initialized := true
            this.Degraded := !AudioNotificationBridge.Start()
            this.RefreshSettings()
            this._Schedule()
        } finally Thread "NoTimers", false
    }
    static Warn(key, message) {
        if this.Warnings.Has(key) && A_TickCount - this.Warnings[key] < 30000
            return
        this.Warnings[key] := A_TickCount
        Logger.Warn("GameMute", message)
    }
    static QueueAction(pid, kind, delta, callback) {
        if !this.Initialized || this.StopRequested
            return false
        ; 热键只复制已有身份，进程校验与 COM 枚举由工作定时器执行。
        created := this.States.Has(pid) ? this.States[pid].created : ""
        if kind = "volume" && this.Actions.Length {
            last := this.Actions[-1]
            if last.kind = kind && last.pid = pid && last.created = created && last.delta * delta > 0 {
                last.delta := Min(1, Max(-1, last.delta + delta))
                last.callback := callback
                return true
            }
        }
        if kind = "volume" && this.Actions.Length >= 16
            return false
        this.Actions.Push({pid: pid, kind: kind, delta: delta, callback: callback, created: created})
        this._QueueWake()
        return true
    }
    static Notify(kind, detail, *) {
        if !this.Initialized || this.StopRequested
            return
        this.Notices.Push({kind: kind, detail: detail})
        this.RequestSync()
    }
    static _ApplyNotices() {
        Loop 32 {
            if !this.Notices.Length
                break
            notice := this.Notices.RemoveAt(1)
            this.Notifications++
            if notice.kind = 4 {
                this.Degraded := true
                this.Warn("notification", "音频通知已降级为 250ms 巡检：" GameAudioMute._FormatHResult(notice.detail))
            } else if notice.kind = 5 {
                this.Degraded := false
                Logger.Info("GameMute", "音频通知已恢复")
            }
            this.BurstUntil := A_TickCount + 2000
        }
    }
    static _QueueWake() {
        if !this.Initialized || this.StopRequested || this.WakeQueued
            return
        this.WakeQueued := true
        SetTimer(this.WakeTimer, -1)
    }
    static _Wake() {
        this.WakeQueued := false
        this.Tick()
    }
    static _Schedule() {
        if !this.Initialized || this.StopRequested
            return
        next := this.Degraded ? 250 : (A_TickCount < this.BurstUntil ? 100 : 1000)
        if next != this.Interval {
            this.Interval := next
            SetTimer(this.Timer, next)
        }
    }
    static RequestSync(*) {
        if !this.Initialized || this.StopRequested
            return
        this.SyncPending := true
        this._QueueWake()
    }
    static UpdateTargets(targets) {
        signature := ""
        for pid in targets
            signature .= pid ":" this.States[pid].created ";"
        if signature = this.TargetSignature
            return
        if AudioNotificationBridge.UpdateTargets(targets) {
            this.TargetSignature := signature
        } else {
            this.Degraded := true
            this.Warn("targets", "更新音频通知目标失败，已退回 250ms 巡检")
        }
    }
    static _Failure(message) {
        return {success: false, found: 0, failed: 1,
            message: message, pending: 0, volume: "", volumeFailed: 0,
            muteFailed: 0, volumePending: 0, manual: false, background: false}
    }
    static _Execute(action, snapshot) {
        try {
            if !action.pid
                return this._Failure("未指定目标进程")
            state := this.GetState(action.pid, action.created)
            switch action.kind {
                case "mute":
                    state.manual := !state.manual
                    state.volumeUnmute := false
                    for _, record in state.sessions
                        record.manualEnforced := false
                    if !state.manual
                        this.RequestUnmute(state)
                    result := this.Reconcile(action.pid, state, snapshot,
                        this.ShouldMute(state.manual, GameClientRegistry.ForegroundPid != action.pid, this.AutoEnabled))
                case "volume":
                    if !IsNumber(action.delta)
                        return this._Failure("无效的音量变化值")
                    result := this.AdjustSnapshot(action.pid, state, snapshot, action.delta)
                default: return this._Failure("无效的音频操作")
            }
            if !result.success || result.volumePending || result.pending
                this.BurstUntil := A_TickCount + 2000
            return result
        } catch Error as e {
            return this._Failure(e.Message)
        }
    }
    static Tick() {
        if !this.Initialized || this.StopRequested
            return
        if this.Busy {
            this.RequestSync()
            return
        }
        Thread "NoTimers"
        this.Busy := true
        generation := this.Generation
        completed := []
        try {
            this.SyncPending := false
            if this.SettingsPending {
                this.SettingsPending := false
                this.AutoEnabled := Config.ReadImportantFromIni("AutoMuteBackground") = "1"
            }
            this._ApplyNotices()
            if !this.StopRequested
                this._SyncClients(completed)
        } catch Error as e {
            this.Warn("tick", "静音巡检失败：" e.Message)
        } finally {
            try {
                for item in completed {
                    if !this.Initialized || this.StopRequested || this.Generation != generation
                        break
                    if IsObject(item.action.callback) {
                        try item.action.callback.Call(item.action.kind, item.result)
                        catch Error as e
                            this.Warn("callback", "音频操作回调失败：" e.Message)
                    }
                }
            } finally {
                this.Busy := false
                try {
                    if this.StopRequested {
                        this.Stop()
                    } else {
                        this._Schedule()
                        if this.Actions.Length || this.Notices.Length || this.SyncPending || this.SettingsPending
                            this._QueueWake()
                    }
                } finally Thread "NoTimers", false
            }
        }
    }
    static _SyncClients(completed) {
        for client in GameClientRegistry.GetClients() {
            try this.GetState(client.pid)
            catch Error as e
                this.Warn("identity-" client.pid, e.Message)
        }
        batch := []
        Loop Min(4, this.Actions.Length) {
            action := this.Actions.RemoveAt(1)
            try {
                action.created := this.GetState(action.pid, action.created).created
                batch.Push(action)
            } catch Error as e {
                completed.Push({action: action, result: this._Failure(e.Message)})
            }
        }
        targets := Map(), gone := []
        for pid, state in this.States {
            created := this.Identity(pid)
            if StrLen(created) = 0 {
                if !ProcessExist(pid)
                    gone.Push(pid)
                continue
            }
            if created != state.created {
                gone.Push(pid)
                continue
            }
            targets[pid] := true
        }
        for pid in gone
            this.States.Delete(pid)
        this.UpdateTargets(targets)
        active := Map()
        for pid in targets {
            state := this.States[pid]
            if this.ShouldMute(state.manual, GameClientRegistry.ForegroundPid != pid, this.AutoEnabled)
                || IsNumber(state.volumeTarget) || state.volumeQueued || state.unmutePending
                || state.sessions.Count || state.deferred.Count
                active[pid] := true
        }
        for action in batch {
            if targets.Has(action.pid)
                active[action.pid] := true
        }
        if !active.Count {
            for action in batch
                completed.Push({action: action, result: this._Failure("游戏进程已退出或重启，未操作旧会话")})
            return
        }
        snapshot := GameAudioMute.Capture(active)
        try {
            handled := Map()
            for action in batch {
                if this.StopRequested
                    break
                completed.Push({action: action, result: this._Execute(action, snapshot)})
                handled[action.pid] := true
            }
            for pid in active {
                if this.StopRequested || handled.Has(pid)
                    continue
                state := this.States[pid]
                if this.Identity(pid) != state.created
                    continue
                wanted := this.ShouldMute(state.manual, GameClientRegistry.ForegroundPid != pid, this.AutoEnabled)
                result := this.Reconcile(pid, state, snapshot, wanted)
                if !result.success
                    this.Warn("sync-" pid, "同步未完全成功：pid=" pid " " result.message)
            }
        } finally GameAudioMute.ReleaseSnapshot(snapshot)
    }
    static Restore(state) {
        snapshot := GameAudioMute.Capture(Map(state.pid, true))
        try {
            if this.Identity(state.pid) != state.created
                return {success: false, found: 0, failed: 1, pending: 0, message: "游戏进程身份已变化"}
            ; 待完成的 Up 需先补写目标音量；一般自动恢复不改音量。
            return this.Reconcile(state.pid, state, snapshot, false, state.volumeUnmute)
        }
        finally GameAudioMute.ReleaseSnapshot(snapshot)
    }
    static JournalPath() {
        SplitPath(Config.IniFile, , &directory)
        return directory "\mute-restore.ini"
    }
    static LoadPending() {
        path := this.JournalPath()
        if !FileExist(path)
            return
        try {
            count := Min(10000, Max(0, Integer(IniRead(path, "Main", "Count", "0"))))
            Loop count {
                section := "Record" A_Index
                pid := Integer(IniRead(path, section, "Pid", "0"))
                created := IniRead(path, section, "Created", "")
                if !pid || StrLen(created) = 0 || this.Identity(pid) != created
                    continue
                state := this.GetState(pid)
                record := {device: IniRead(path, section, "Device"), id: IniRead(path, section, "Id"),
                    instance: IniRead(path, section, "Instance"), muted: IniRead(path, section, "Muted") = "1"}
                state.deferred[this.Key(record)] := record
            }
        } catch Error as e {
            this.Warn("journal-read", "读取待恢复静音记录失败：" e.Message)
        }
    }
    static SavePending() {
        if StrLen(Config.IniFile) = 0
            return
        path := this.JournalPath(), temp := path ".tmp-" DllCall("GetCurrentProcessId", "UInt")
        count := 0
        try {
            if FileExist(temp)
                FileDelete(temp)
            for pid, state in this.States {
                if state.manual || this.Identity(pid) != state.created
                    continue
                for records in [state.sessions, state.deferred] {
                    for _, record in records {
                        section := "Record" (++count)
                        for key, value in Map("Pid", pid, "Created", state.created, "Device", record.device,
                            "Id", record.id, "Instance", record.instance, "Muted", record.muted ? "1" : "0")
                            IniWrite(value, temp, section, key)
                    }
                }
            }
            if count {
                IniWrite(count, temp, "Main", "Count")
                FileMove(temp, path, 1)
                this.Warn("journal-save", "退出时仍有 " count " 个断开的会话待恢复；下次启动后继续")
            } else if FileExist(path)
                FileDelete(path)
        } catch Error as e {
            this.Warn("journal-save", "保存待恢复静音记录失败：" e.Message)
        }
    }
    ; exiting 仅供退出回调使用，保证进程终止前同步恢复自动静音。
    static Stop(exiting := false, *) {
        if this.Busy && !exiting {
            this.StopRequested := true
            return
        }
        if !this.Initialized && !this.States.Count {
            AudioNotificationBridge.Stop()
            return
        }
        Thread "NoTimers"
        try {
            this.Generation++
            this.Initialized := false
            if this.Timer
                SetTimer(this.Timer, 0)
            if this.WakeTimer
                SetTimer(this.WakeTimer, 0)
            if this.SyncCallback {
                EventBus.Unsubscribe("ForegroundClientChanged", this.SyncCallback)
                EventBus.Unsubscribe("GameClientsChanged", this.SyncCallback)
            }
            this.Actions := []
            this.Notices := []
            this.WakeQueued := false
            this.SyncPending := false
            this.SettingsPending := false
            this.Interval := 0
            this.TargetSignature := ""
            this.BurstUntil := 0
            this.Timer := 0
            this.WakeTimer := 0
            this.SyncCallback := 0
            AudioNotificationBridge.Stop()
            for pid, state in this.States {
                if !state.manual && this.Identity(pid) = state.created {
                    try this.Restore(state)
                    catch Error as e
                        this.Warn("exit-" pid, "退出恢复失败：" e.Message)
                }
            }
            this.SavePending()
            this.States.Clear()
            this.StopRequested := false
            Logger.Info("GameMute", "静音统计：扫描=" GameAudioMute.ScanCount " 写入=" GameAudioMute.WriteCount
                " 通知=" this.Notifications " 降级=" (this.Degraded ? "1" : "0"))
        } finally Thread "NoTimers", false
        if this.RestartRequested {
            this.RestartRequested := false
            this.Init()
        }
    }
}
