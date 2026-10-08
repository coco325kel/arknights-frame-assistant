; == MTA 音频通知模块桥接 ==
class AudioNotificationBridge {
    static Module := 0
    static Handle := 0
    static Message := 0
    static Callback := 0
    static Stopping := false

    static Start() {
        if this.Handle && !this.Stopping
            return true
        try {
            if A_PtrSize != 8
                throw Error("音频通知模块仅支持 x64")
            if this.Stopping
                this.Stop()
            if this.Module
                throw Error("上一次音频通知尚未完成注销")
            path := this._ExtractModule()
            this.Message := DllCall("RegisterWindowMessageW", "WStr", "AFA.AudioNotify.v1", "UInt")
            if !this.Message
                throw Error("注册音频通知消息失败")
            this.Callback := GameMuteController.Notify.Bind(GameMuteController)
            OnMessage(this.Message, this.Callback)
            this.Module := DllCall("LoadLibraryExW", "WStr", path, "Ptr", 0, "UInt", 0x100 | 0x800, "Ptr")
            if !this.Module
                throw Error("加载音频通知模块失败：" A_LastError)
            handle := 0
            hr := DllCall(this.Proc("AfaAudioStart"), "Ptr", A_ScriptHwnd, "UInt", this.Message, "Ptr*", &handle, "Int")
            this.Handle := handle
            if hr < 0
                throw Error(GameAudioMute._FormatHResult(hr))
            Logger.Info("GameMute", "MTA 音频通知监听已启动")
            return true
        } catch Error as e {
            this.Stop()
            GameMuteController.Warn("native-start", "音频通知无法启动，退回 250ms 巡检：" e.Message)
            return false
        }
    }

    static _ExtractModule() {
        sourceDir := A_ScriptDir "\resources\audio"
        directory := FileExtractor.ResourcesDir
        DirCreate(directory)
        manifest := sourceDir "\AudioNotify.sha256"
        if A_IsCompiled {
            manifest := directory "\AudioNotify.sha256"
            FileInstall "resources\audio\AudioNotify.sha256", manifest, 1
        }
        digest := StrLower(Trim(FileRead(manifest, "UTF-8")))
        if !RegExMatch(digest, "^[0-9a-f]{64}$")
            throw Error("音频通知模块校验清单无效")
        path := directory "\AudioNotify-" digest ".dll"
        if !FileExist(path) || UpdateDownloader._GetFileSha256(path) != digest {
            if A_IsCompiled
                FileInstall "resources\audio\AudioNotify.dll", path, 1
            else
                FileCopy(sourceDir "\AudioNotify.dll", path, 1)
        }
        if UpdateDownloader._GetFileSha256(path) != digest
            throw Error("音频通知模块 SHA-256 校验失败")
        return path
    }

    static Proc(name) {
        address := DllCall("GetProcAddress", "Ptr", this.Module, "AStr", name, "Ptr")
        if !address
            throw Error("音频通知模块缺少接口：" name)
        return address
    }

    static UpdateTargets(targets) {
        if !this.Handle
            return false
        data := Buffer(Max(4, targets.Count * 4)), index := 0
        for pid in targets
            NumPut("UInt", pid, data, index++ * 4)
        try return DllCall(this.Proc("AfaAudioUpdateTargets"), "Ptr", this.Handle, "Ptr", data, "UInt", targets.Count, "Int") >= 0
        catch
            return false
    }

    static Stop() {
        if this.Handle {
            this.Stopping := true
            hr := DllCall(this.Proc("AfaAudioStop"), "Ptr", this.Handle, "Int")
            if hr < 0 {
                GameMuteController.Warn("native-stop", "通知注销未完成，保留已加载模块至进程退出：" GameAudioMute._FormatHResult(hr))
                return
            }
            this.Handle := 0
        }
        if this.Callback && this.Message
            OnMessage(this.Message, this.Callback, 0)
        this.Callback := 0
        if this.Module {
            DllCall("FreeLibrary", "Ptr", this.Module)
            this.Module := 0
        }
        this.Stopping := false
    }
}
