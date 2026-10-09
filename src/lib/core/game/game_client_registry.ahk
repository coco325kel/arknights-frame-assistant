; == 游戏客户端实例注册表 ==
; 枚举运行中的 Arknights.exe 实例、维护 PID→区服缓存、仲裁前台客户端并发布事实事件；
; 枚举/路径查询是慢路径，热键路径不得进入本模块的 IO 方法。

class GameClientRegistry {

    ; pid -> {pid, hwnd, exePath, serverId}
    static Clients := Map()
    static ClientList := []
    static ForegroundPid := 0
    static _LastForegroundPid := 0
    static _LastClientsSignature := ""
    static _Initialized := false
    static _RefreshScheduled := false
    static _RefreshInProgress := false

    ; 初始化
    static Init() {
        if (this._Initialized)
            return
        this._Initialized := true
        this.Refresh()
    }

    ; 是否有受管客户端在运行
    static HasClients() {
        return this.Clients.Count > 0
    }

    ; 客户端数组（副本）
    static GetClients() {
        result := []
        for client in this.ClientList
            result.Push(client)
        return result
    }

    ; 按 pid 查找客户端
    static GetByPid(pid) {
        if (this.Clients.Has(pid))
            return this.Clients[pid]
        return ""
    }

    ; 按 hwnd 查找客户端
    static GetByHwnd(hwnd) {
        for _, client in this.Clients {
            if (client.hwnd = hwnd)
                return client
        }
        return ""
    }

    ; 当前前台客户端
    static GetForegroundClient() {
        return this.GetByPid(this.ForegroundPid)
    }

    ; 当前前台区服 id
    static GetForegroundServerId() {
        client := this.GetForegroundClient()
        return client = "" ? "" : client.serverId
    }

    ; 热键路径缓存未命中时投递一次异步补识别
    static ScheduleRefresh() {
        if (this._RefreshScheduled)
            return
        this._RefreshScheduled := true
        SetTimer ObjBindMethod(GameClientRegistry, "_DelayedRefresh"), -1
    }

    static _DelayedRefresh() {
        this._RefreshScheduled := false
        this.Refresh()
    }

    ; 刷新客户端列表与前台客户端（重入保护）
    static Refresh() {
        if (this._RefreshInProgress)
            return
        this._RefreshInProgress := true
        try {
            newClients := Map()
            previousHiddenWindows := A_DetectHiddenWindows
            try {
                DetectHiddenWindows true
                hwnds := WinGetList("ahk_exe Arknights.exe")
                for hwnd in hwnds {
                    if !DllCall("IsWindowVisible", "Ptr", hwnd)
                        continue
                    try pid := WinGetPID("ahk_id " hwnd)
                    catch Error
                        continue
                    if (pid = 0 || newClients.Has(pid))
                        continue
                    exePath := this._GetProcessPath(pid)
                    info := ServerProfile.FromExePath(exePath)
                    newClients[pid] := {
                        pid: pid,
                        hwnd: hwnd,
                        exePath: exePath,
                        serverId: info.serverId
                    }
                }
            } catch Error as e {
                Logger.Warn("GameClientRegistry", "枚举游戏客户端失败：" e.Message)
            } finally {
                DetectHiddenWindows previousHiddenWindows
            }

            if (this._ClientsChanged(newClients)) {
                this.Clients := newClients
                this.ClientList := []
                for _, client in this.Clients
                    this.ClientList.Push(client)
                EventBus.Publish("GameClientsChanged", {clients: this.GetClients()})
                Logger.Info("GameClientRegistry", "客户端集合变化，当前数量=" this.ClientList.Length)
            } else {
                this.Clients := newClients
                this.ClientList := []
                for _, client in this.Clients
                    this.ClientList.Push(client)
            }

            this._RefreshForeground()
        } finally {
            this._RefreshInProgress := false
        }
    }

    ; 比较两个客户端集合是否一致
    static _ClientsChanged(newClients) {
        if (this.Clients.Count != newClients.Count)
            return true
        for pid, client in newClients {
            old := this.GetByPid(pid)
            if (old = "")
                return true
            if (old.hwnd != client.hwnd || old.exePath != client.exePath || old.serverId != client.serverId)
                return true
        }
        return false
    }

    ; 仲裁前台客户端并更新 GameTarget
    static _RefreshForeground() {
        fgHwnd := DllCall("GetForegroundWindow", "Ptr")
        fgPid := 0
        DllCall("GetWindowThreadProcessId", "Ptr", fgHwnd, "UInt*", &fgPid)
        client := this.GetByPid(fgPid)
        previousPid := this.ForegroundPid
        previousClient := this.GetByPid(previousPid)
        previousServerId := previousClient = "" ? "" : previousClient.serverId

        if (client != "") {
            this.ForegroundPid := client.pid
            GameTarget.Bind(client.hwnd, client.pid, client.exePath, client.serverId)
        } else {
            this.ForegroundPid := 0
            GameTarget.Unbind()
        }

        if (this.ForegroundPid != previousPid) {
            EventBus.Publish("ForegroundClientChanged", {
                pid: this.ForegroundPid,
                hwnd: client = "" ? "" : client.hwnd,
                serverId: client = "" ? "" : client.serverId,
                previousServerId: previousServerId
            })
        }
    }

    ; 获取进程路径（ProcessGetPath 失败降级 WMI）
    static _GetProcessPath(pid) {
        try {
            path := ProcessGetPath(pid)
            if (path != "")
                return path
        } catch Error as e {
            Logger.Warn("GameClientRegistry", "ProcessGetPath 异常 (pid=" pid "): " e.Message)
        }
        return this._GetProcessPathByWmi(pid)
    }

    ; WMI 降级查询
    static _GetProcessPathByWmi(pid) {
        try {
            wmi := ComObject("winmgmts:{impersonationLevel=impersonate}!\\.\root\cimv2")
            query := "SELECT ExecutablePath FROM Win32_Process WHERE ProcessId = " pid
            for process in wmi.ExecQuery(query) {
                path := Trim(process.ExecutablePath)
                if (path != "")
                    return path
            }
            return ""
        } catch Error as e {
            Logger.Error("GameClientRegistry", "WMI 查询失败: " e.Message)
            return ""
        }
    }
}
