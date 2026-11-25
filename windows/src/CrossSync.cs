using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Net;
using System.Net.NetworkInformation;
using System.Net.Sockets;
using System.Security.Cryptography;
using System.Text;
using System.Threading;
using System.Web.Script.Serialization;

namespace Pegline
{
    enum SyncState
    {
        Disabled,
        Connecting,
        Connected,
        Error
    }

    class RemoteDevice
    {
        public string Name;
        public string Platform;

        public string Icon
        {
            get { return IconFor(Platform); }
        }

        public static string IconFor(string platform)
        {
            switch ((platform ?? "").ToLowerInvariant())
            {
                case "macos": return "[Mac]";
                case "windows": return "[Win]";
                case "ios": return "[iOS]";
                case "android": return "[And]";
                case "web": return "[Web]";
                default: return "[Sync]";
            }
        }
    }

    /// Cross-device clipboard sync engine (SSE + REST, zero external deps).
    /// Shares the exact same protocol as macOS Clipline and clip-hub.
    sealed class CrossSync
    {
        public static readonly CrossSync Instance = new CrossSync();

        const int MaxBytes = 10 * 1024 * 1024;
        readonly JavaScriptSerializer json = new JavaScriptSerializer { MaxJsonLength = 24 * 1024 * 1024 };
        readonly object dedupLock = new object();
        readonly Dictionary<string, DateTime> recentHashes = new Dictionary<string, DateTime>();
        readonly object stateLock = new object();

        CancellationTokenSource cts;
        LocalWindowsHub localHub;
        string activeHubURL = "";
        long lastClipId = 0;
        readonly List<PendingClip> pendingOutbound = new List<PendingClip>();
        readonly List<string> diagLogs = new List<string>();
        Timer networkDebounceTimer;

        sealed class PendingClip
        {
            public string Kind;
            public string Text;
            public byte[] Png;
        }

        public SyncState State { get; private set; }
        public string ErrorText { get; private set; }
        public List<RemoteDevice> OnlineDevices { get; private set; }

        public event Action Changed;
        public Action<string, string> OnRemoteText;
        public Action<byte[], string> OnRemoteImage;

        CrossSync()
        {
            ServicePointManager.SecurityProtocol =
                (SecurityProtocolType)3072 | (SecurityProtocolType)12288 | SecurityProtocolType.Tls12;
            ServicePointManager.DefaultConnectionLimit = 16;
            ServicePointManager.Expect100Continue = false;
            OnlineDevices = new List<RemoteDevice>();
            State = SyncState.Disabled;
            ErrorText = "";
            BootstrapDefaults();
            MigratePlaintextTokenOnce();
            try
            {
                NetworkChange.NetworkAddressChanged += delegate { ScheduleNetworkReconnect("network changed"); };
                Microsoft.Win32.SystemEvents.PowerModeChanged += (s, e) =>
                {
                    if (e.Mode == Microsoft.Win32.PowerModes.Resume)
                        ScheduleNetworkReconnect("system resume");
                };
            }
            catch (Exception) { }
        }

        void ScheduleNetworkReconnect(string reason)
        {
            if (!Enabled) return;
            lock (stateLock)
            {
                if (networkDebounceTimer != null)
                {
                    try { networkDebounceTimer.Dispose(); } catch (Exception) { }
                }
                networkDebounceTimer = new Timer(_ =>
                {
                    if (!Enabled) return;
                    LogDiag(reason + " -> reconnect");
                    Restart();
                }, null, 900, Timeout.Infinite);
            }
        }

        void LogDiag(string msg)
        {
            lock (diagLogs)
            {
                diagLogs.Add("[" + DateTime.Now.ToString("HH:mm:ss") + "] " + msg);
                if (diagLogs.Count > 40) diagLogs.RemoveAt(0);
            }
        }

        public string DeviceId
        {
            get
            {
                string id = Settings.GetString("sync.deviceId");
                if (string.IsNullOrWhiteSpace(id))
                {
                    id = Guid.NewGuid().ToString("D");
                    Settings.SetString("sync.deviceId", id);
                }
                return id.Trim();
            }
        }

        string LastWorkingHub
        {
            get { return Settings.GetString("sync.lastWorkingHub") ?? ""; }
            set { Settings.SetString("sync.lastWorkingHub", (value ?? "").Trim()); }
        }

        void BootstrapDefaults()
        {
            if (Settings.GetString("sync.initialized") != null) return;
            Settings.SetString("sync.initialized", "1");
            Settings.Set("sync.syncImages", true);
            if (string.IsNullOrEmpty(Settings.GetString("sync.deviceName")))
                Settings.SetString("sync.deviceName", Environment.MachineName.ToLowerInvariant());

            // Auto-import token from %LOCALAPPDATA%\ClipSync\token.txt if present
            try
            {
                string tokFile = Path.Combine(
                    Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
                    "ClipSync", "token.txt");
                string hubFile = Path.Combine(
                    Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
                    "ClipSync", "hub.txt");
                if (File.Exists(tokFile) && File.Exists(hubFile))
                {
                    string tok = File.ReadAllText(tokFile).Trim();
                    string hub = File.ReadAllText(hubFile).Trim();
                    if (!string.IsNullOrEmpty(tok) && !string.IsNullOrEmpty(hub))
                    {
                        Token = tok;
                        if (string.IsNullOrEmpty(Settings.GetString("sync.hubURL")))
                            Settings.SetString("sync.hubURL", hub);
                        Settings.Set("sync.enabled", true);
                    }
                }
            }
            catch (Exception) { }
        }

        public bool Enabled
        {
            get { return Settings.Get("sync.enabled"); }
            set { Settings.Set("sync.enabled", value); if (value) Restart(); else Stop(); }
        }

        public bool HostMode
        {
            get { return Settings.Get("sync.hostMode"); }
            set
            {
                Settings.Set("sync.hostMode", value);
                if (value && string.IsNullOrWhiteSpace(Token)) Token = GenerateToken();
                if (Enabled) Restart(); else Notify();
            }
        }

        public int HostPort
        {
            get
            {
                int p;
                return int.TryParse(Settings.GetString("sync.hostPort"), out p) && p > 0 ? p : 8765;
            }
            set { Settings.SetString("sync.hostPort", value.ToString()); }
        }

        public string HubURL
        {
            get { return Settings.GetString("sync.hubURL") ?? ""; }
            set { Settings.SetString("sync.hubURL", (value ?? "").Trim()); }
        }

        void MigratePlaintextTokenOnce()
        {
            string raw = Settings.GetString("sync.token") ?? "";
            if (!string.IsNullOrEmpty(raw) && !raw.StartsWith("dpapi:", StringComparison.Ordinal))
            {
                Token = raw;
            }
        }

        public string Token
        {
            get
            {
                string raw = Settings.GetString("sync.token") ?? "";
                if (string.IsNullOrEmpty(raw)) return "";
                if (raw.StartsWith("dpapi:", StringComparison.Ordinal))
                {
                    try
                    {
                        byte[] enc = Convert.FromBase64String(raw.Substring(6));
                        byte[] plain = ProtectedData.Unprotect(enc, null, DataProtectionScope.CurrentUser);
                        return Encoding.UTF8.GetString(plain);
                    }
                    catch (Exception) { return ""; }
                }
                return raw;
            }
            set
            {
                string v = (value ?? "").Trim();
                if (string.IsNullOrEmpty(v))
                {
                    Settings.SetString("sync.token", "");
                    return;
                }
                try
                {
                    byte[] enc = ProtectedData.Protect(Encoding.UTF8.GetBytes(v), null, DataProtectionScope.CurrentUser);
                    Settings.SetString("sync.token", "dpapi:" + Convert.ToBase64String(enc));
                }
                catch (Exception)
                {
                    Settings.SetString("sync.token", v);
                }
            }
        }

        public string DeviceName
        {
            get
            {
                string d = Settings.GetString("sync.deviceName");
                return string.IsNullOrWhiteSpace(d) ? Environment.MachineName.ToLowerInvariant() : d.Trim();
            }
            set { Settings.SetString("sync.deviceName", (value ?? "").Trim()); }
        }

        public bool SyncImages
        {
            get { return Settings.GetString("sync.syncImages") != "0"; }
            set { Settings.Set("sync.syncImages", value); }
        }

        public bool HasTailscale { get { return DetectTailscaleIP() != null; } }

        public string StatusSummary
        {
            get
            {
                if (!Enabled) return Loc.L("Off", "Desactivado", "未开启");
                switch (State)
                {
                    case SyncState.Connected:
                        int n = Math.Max(1, OnlineDevices.Count);
                        return string.Format(Loc.L("Connected ({0} online)", "Conectado ({0})", "已连接（{0} 台在线）"), n);
                    case SyncState.Connecting:
                        return Loc.L("Connecting...", "Conectando...", "连接中…");
                    case SyncState.Error:
                        return string.IsNullOrEmpty(ErrorText) ? Loc.L("Error", "Error", "连接异常") : ErrorText;
                    default:
                        return Loc.L("Off", "Desactivado", "未开启");
                }
            }
        }

        public string ShareableHubURL
        {
            get
            {
                if (HostMode)
                {
                    string ip = DetectTailscaleIP() ?? DetectLANIP() ?? "127.0.0.1";
                    return "http://" + ip + ":" + HostPort;
                }
                var cands = CandidateURLs();
                var https = cands.FirstOrDefault(u => u.StartsWith("https://", StringComparison.OrdinalIgnoreCase));
                if (https != null) return https;
                string first = !string.IsNullOrEmpty(activeHubURL) ? activeHubURL : (cands.FirstOrDefault() ?? ("http://127.0.0.1:" + HostPort));
                try
                {
                    var uri = new Uri(first);
                    if (uri.Host == "127.0.0.1" || uri.Host.Equals("localhost", StringComparison.OrdinalIgnoreCase))
                    {
                        string ip = DetectTailscaleIP() ?? DetectLANIP();
                        if (ip != null)
                        {
                            var b = new UriBuilder(uri) { Host = ip };
                            return b.Uri.ToString().TrimEnd('/');
                        }
                    }
                }
                catch (Exception) { }
                return first;
            }
        }

        public string PairingCode
        {
            get
            {
                if (string.IsNullOrEmpty(Token)) return "";
                string payload = json.Serialize(new Dictionary<string, string>
                {
                    { "hub", ShareableHubURL },
                    { "token", Token }
                });
                return "clipsync://" + Convert.ToBase64String(Encoding.UTF8.GetBytes(payload));
            }
        }

        public string PairingWebURL
        {
            get
            {
                if (string.IsNullOrEmpty(Token)) return ShareableHubURL;
                return ShareableHubURL.TrimEnd('/') + "/#pair=" + Uri.EscapeDataString(Token);
            }
        }

        static string ExtractPairParam(string rawPart)
        {
            if (string.IsNullOrEmpty(rawPart)) return null;
            foreach (var kv in rawPart.Split('&'))
            {
                int idx = kv.IndexOf('=');
                if (idx > 0 && kv.Substring(0, idx) == "pair")
                {
                    string tok = Uri.UnescapeDataString(kv.Substring(idx + 1)).Trim();
                    if (!string.IsNullOrWhiteSpace(tok)) return tok;
                }
            }
            return null;
        }

        public bool ImportPairing(string raw)
        {
            string s = (raw ?? "").Trim();
            if (s.StartsWith("clipsync://", StringComparison.OrdinalIgnoreCase))
            {
                try
                {
                    byte[] data = Convert.FromBase64String(s.Substring("clipsync://".Length));
                    var dict = json.Deserialize<Dictionary<string, object>>(Encoding.UTF8.GetString(data));
                    string hub = dict != null && dict.ContainsKey("hub") ? Convert.ToString(dict["hub"]) : "";
                    string tok = dict != null && dict.ContainsKey("token") ? Convert.ToString(dict["token"]) : "";
                    if (string.IsNullOrWhiteSpace(hub) || string.IsNullOrWhiteSpace(tok)) return false;
                    Settings.Set("sync.hostMode", false);
                    HubURL = hub;
                    Token = tok;
                    Settings.Set("sync.enabled", true);
                    Restart();
                    return true;
                }
                catch (Exception) { return false; }
            }
            try
            {
                var uri = new Uri(s);
                string tok = ExtractPairParam(uri.Fragment.TrimStart('#'))
                          ?? ExtractPairParam(uri.Query.TrimStart('?'));
                if (!string.IsNullOrWhiteSpace(tok))
                {
                    string baseUrl = uri.GetLeftPart(UriPartial.Path).TrimEnd('/');
                    Settings.Set("sync.hostMode", false);
                    HubURL = baseUrl;
                    Token = tok;
                    Settings.Set("sync.enabled", true);
                    Restart();
                    return true;
                }
            }
            catch (Exception) { }
            return false;
        }

        public void StartIfEnabled()
        {
            if (Enabled) Restart();
            else { State = SyncState.Disabled; Notify(); }
        }

        public void Restart()
        {
            StopInternal(false);
            if (!Enabled)
            {
                State = SyncState.Disabled;
                Notify();
                return;
            }

            if (HostMode)
            {
                if (string.IsNullOrWhiteSpace(Token)) Token = GenerateToken();
                localHub = new LocalWindowsHub(HostPort, Token);
                if (!localHub.Start())
                {
                    State = SyncState.Error;
                    ErrorText = Loc.L("Port busy", "Puerto ocupado", "端口 " + HostPort + " 启动失败");
                    Notify();
                    return;
                }
            }

            var cands = HostMode ? new List<string> { "http://127.0.0.1:" + HostPort } : OrderedCandidates();
            if (cands.Count == 0 || string.IsNullOrWhiteSpace(Token))
            {
                State = SyncState.Error;
                ErrorText = Loc.L("Paste pair code", "Pega el código", "请粘贴配对码或开启主机");
                Notify();
                return;
            }

            State = SyncState.Connecting;
            ErrorText = "";
            Notify();

            cts = new CancellationTokenSource();
            var token = cts.Token;
            string authToken = Token;
            string dev = DeviceName;
            string devId = DeviceId;
            bool isHost = HostMode;

            var thread = new Thread(() => SSELoop(cands, authToken, dev, devId, isHost, token))
            {
                IsBackground = true,
                Name = "CrossSyncSSE"
            };
            thread.Start();
        }

        public void Stop()
        {
            StopInternal(true);
        }

        void StopInternal(bool notify)
        {
            if (cts != null)
            {
                try { cts.Cancel(); } catch (Exception) { }
                cts = null;
            }
            if (localHub != null)
            {
                localHub.Stop();
                localHub = null;
            }
            lock (stateLock)
            {
                OnlineDevices = new List<RemoteDevice>();
                activeHubURL = "";
                if (!Enabled) State = SyncState.Disabled;
            }
            if (notify) Notify();
        }

        List<string> CandidateURLs()
        {
            return (HubURL ?? "")
                .Split(new[] { ',' }, StringSplitOptions.RemoveEmptyEntries)
                .Select(s => s.Trim().TrimEnd('/'))
                .Where(s => s.Length > 0)
                .ToList();
        }

        List<string> OrderedCandidates()
        {
            var list = CandidateURLs();
            string last = LastWorkingHub;
            if (!string.IsNullOrEmpty(last))
            {
                int idx = list.IndexOf(last);
                if (idx > 0)
                {
                    list.RemoveAt(idx);
                    list.Insert(0, last);
                }
            }
            return list;
        }

        public void PushText(string text)
        {
            if (!Enabled || string.IsNullOrEmpty(text)) return;
            byte[] raw = Encoding.UTF8.GetBytes(text);
            if (raw.Length > MaxBytes) return;
            string hash = ComputeHash("text", raw);
            if (SeenRecently(hash)) return;
            MarkHash(hash);
            ThreadPool.QueueUserWorkItem(_ => SendClip("text", text, null, true));
        }

        public void PushImage(byte[] png)
        {
            if (!Enabled || !SyncImages || png == null || png.Length == 0 || png.Length > MaxBytes) return;
            string hash = ComputeHash("image", png);
            if (SeenRecently(hash)) return;
            MarkHash(hash);
            ThreadPool.QueueUserWorkItem(_ => SendClip("image", null, png, true));
        }

        void FlushPendingOutbound()
        {
            List<PendingClip> batch;
            lock (pendingOutbound)
            {
                if (pendingOutbound.Count == 0) return;
                batch = pendingOutbound.ToList();
                pendingOutbound.Clear();
            }
            foreach (var p in batch)
                ThreadPool.QueueUserWorkItem(_ => SendClip(p.Kind, p.Text, p.Png, false));
        }

        void SendClip(string kind, string text, byte[] png, bool enqueueOnFail)
        {
            var targets = new List<string>();
            if (HostMode) targets.Add("http://127.0.0.1:" + HostPort);
            else
            {
                lock (stateLock)
                {
                    if (!string.IsNullOrEmpty(activeHubURL)) targets.Add(activeHubURL);
                }
                foreach (var c in OrderedCandidates())
                    if (!targets.Contains(c)) targets.Add(c);
            }
            string tok = Token;
            string dev = DeviceName;
            string devId = DeviceId;
            if (targets.Count == 0 || string.IsNullOrEmpty(tok)) return;

            var dict = new Dictionary<string, string>
            {
                { "kind", kind },
                { "device", dev },
                { "device_id", devId },
                { "platform", "windows" }
            };
            if (kind == "text") dict["text"] = text;
            else
            {
                dict["mime"] = "image/png";
                dict["data_base64"] = Convert.ToBase64String(png);
            }
            byte[] body = Encoding.UTF8.GetBytes(json.Serialize(dict));

            foreach (var baseUrl in targets)
            {
                try
                {
                    var req = CreateRequest(baseUrl + "/api/clip", "POST", tok, 8000);
                    req.ContentType = "application/json";
                    req.Headers["X-Device"] = dev;
                    req.Headers["X-Device-Id"] = devId;
                    req.Headers["X-Platform"] = "windows";
                    req.ContentLength = body.Length;
                    using (var s = req.GetRequestStream()) s.Write(body, 0, body.Length);
                    using (var resp = (HttpWebResponse)req.GetResponse())
                    {
                        if ((int)resp.StatusCode < 300)
                        {
                            lock (stateLock) { activeHubURL = baseUrl; }
                            if (!HostMode) LastWorkingHub = baseUrl;
                            return;
                        }
                    }
                }
                catch (Exception ex) { LogDiag("push " + kind + " fail: " + ex.Message); }
            }
            if (enqueueOnFail)
            {
                lock (pendingOutbound)
                {
                    pendingOutbound.Add(new PendingClip { Kind = kind, Text = text, Png = png });
                    if (pendingOutbound.Count > 3) pendingOutbound.RemoveAt(0);
                }
            }
        }

        void SSELoop(List<string> candidates, string tok, string dev, string devId, bool isHost, CancellationToken ct)
        {
            if (isHost) Thread.Sleep(250);
            int idx = 0;
            int backoffMs = 1000;
            while (!ct.IsCancellationRequested)
            {
                string baseUrl = candidates[idx % candidates.Count];
                idx++;
                HttpWebRequest req = null;
                try
                {
                    string sseUrl = baseUrl + "/api/events?device=" + Uri.EscapeDataString(dev)
                        + "&device_id=" + Uri.EscapeDataString(devId)
                        + "&platform=windows&meta=1";
                    long since = Interlocked.Read(ref lastClipId);
                    if (since > 0) sseUrl += "&since=" + since;
                    req = CreateRequest(sseUrl, "GET", tok, 8000);
                    req.ReadWriteTimeout = 35000;
                    using (ct.Register(() => { try { req.Abort(); } catch (Exception) { } }))
                    using (var resp = (HttpWebResponse)req.GetResponse())
                    {
                        if (resp.StatusCode != HttpStatusCode.OK)
                        {
                            SetError(resp.StatusCode == HttpStatusCode.Unauthorized ? "Token 无效" : "HTTP " + (int)resp.StatusCode);
                            WaitCancel(ct, 4000);
                            continue;
                        }
                        backoffMs = 1000;
                        lock (stateLock)
                        {
                            activeHubURL = baseUrl;
                            State = SyncState.Connected;
                            ErrorText = "";
                        }
                        if (!isHost) LastWorkingHub = baseUrl;
                        LogDiag("SSE connected " + baseUrl);
                        Notify();
                        FlushPendingOutbound();

                        using (var reader = new StreamReader(resp.GetResponseStream(), Encoding.UTF8))
                        {
                            string eventType = "";
                            string line;
                            while (!ct.IsCancellationRequested && (line = reader.ReadLine()) != null)
                            {
                                if (line.StartsWith("event:"))
                                    eventType = line.Substring(6).Trim();
                                else if (line.StartsWith("data:"))
                                    HandleEvent(eventType, line.Substring(5).Trim(), dev, devId, baseUrl, tok);
                                else if (line.Length == 0)
                                    eventType = "";
                            }
                        }
                    }
                }
                catch (WebException ex)
                {
                    if (ct.IsCancellationRequested) break;
                    var httpResp = ex.Response as HttpWebResponse;
                    if (httpResp != null && httpResp.StatusCode == HttpStatusCode.Unauthorized)
                    {
                        SetError("Token 无效");
                        WaitCancel(ct, 5000);
                        continue;
                    }
                    LogDiag("SSE err (" + baseUrl + "): " + ex.Message);
                    lock (stateLock) { if (State == SyncState.Connected) State = SyncState.Connecting; }
                    Notify();
                }
                catch (Exception ex)
                {
                    if (ct.IsCancellationRequested) break;
                    LogDiag("SSE err (" + baseUrl + "): " + ex.Message);
                    lock (stateLock) { if (State == SyncState.Connected) State = SyncState.Connecting; }
                    Notify();
                }
                int waitMs = (candidates.Count > 1 && idx % candidates.Count != 0) ? 400 : backoffMs;
                WaitCancel(ct, waitMs);
                if (idx % candidates.Count == 0) backoffMs = Math.Min(backoffMs * 2, 15000);
            }
        }

        void HandleEvent(string type, string data, string localDev, string localDevId, string baseUrl, string authToken)
        {
            try
            {
                if (type == "ready")
                {
                    var obj = json.Deserialize<Dictionary<string, object>>(data);
                    if (obj != null)
                    {
                        if (obj.ContainsKey("devices"))
                            UpdateDevices(obj["devices"] as object[]);
                        long lid = GetLong(obj, "latest_id");
                        if (lid > Interlocked.Read(ref lastClipId)) Interlocked.Exchange(ref lastClipId, lid);
                    }
                }
                else if (type == "devices")
                {
                    var arr = json.Deserialize<object[]>(data);
                    UpdateDevices(arr);
                }
                else if (type == "clip")
                {
                    var obj = json.Deserialize<Dictionary<string, object>>(data);
                    if (obj == null) return;
                    long cid = GetLong(obj, "id");
                    if (cid > Interlocked.Read(ref lastClipId)) Interlocked.Exchange(ref lastClipId, cid);
                    string dev = GetStr(obj, "device");
                    string devId = GetStr(obj, "device_id");
                    string hash = GetStr(obj, "hash");
                    string kind = GetStr(obj, "kind");
                    bool isSelf = !string.IsNullOrEmpty(devId)
                        ? string.Equals(devId, localDevId, StringComparison.OrdinalIgnoreCase)
                        : string.Equals(dev, localDev, StringComparison.OrdinalIgnoreCase);
                    if (isSelf || SeenRecently(hash))
                        return;
                    MarkHash(hash);

                    string badge = dev;
                    if (kind == "text")
                    {
                        string text = GetStr(obj, "text");
                        if (!string.IsNullOrEmpty(text) && OnRemoteText != null)
                            OnRemoteText(text, badge);
                    }
                    else if (kind == "image" && SyncImages)
                    {
                        string b64 = GetStr(obj, "data_base64");
                        if (!string.IsNullOrEmpty(b64) && OnRemoteImage != null)
                        {
                            byte[] png = Convert.FromBase64String(b64);
                            if (png.Length > 0) OnRemoteImage(png, badge);
                        }
                        else if (cid > 0 && OnRemoteImage != null)
                        {
                            ThreadPool.QueueUserWorkItem(_ => FetchRemoteImage(baseUrl, authToken, cid, badge));
                        }
                    }
                }
            }
            catch (Exception) { }
        }

        void FetchRemoteImage(string baseUrl, string authToken, long clipId, string badge)
        {
            try
            {
                var req = CreateRequest(baseUrl + "/api/history/" + clipId + "/raw", "GET", authToken, 15000);
                using (var resp = (HttpWebResponse)req.GetResponse())
                {
                    if (resp.StatusCode != HttpStatusCode.OK) return;
                    using (var ms = new MemoryStream())
                    {
                        resp.GetResponseStream().CopyTo(ms);
                        byte[] bytes = ms.ToArray();
                        if (bytes.Length > 0 && OnRemoteImage != null)
                            OnRemoteImage(bytes, badge);
                    }
                }
            }
            catch (Exception ex) { LogDiag("fetch img #" + clipId + " fail: " + ex.Message); }
        }

        static long GetLong(Dictionary<string, object> d, string key)
        {
            object v;
            long n;
            return d.TryGetValue(key, out v) && v != null && long.TryParse(Convert.ToString(v), out n) ? n : 0;
        }

        void UpdateDevices(object[] arr)
        {
            if (arr == null) return;
            var list = new List<RemoteDevice>();
            foreach (var item in arr)
            {
                var d = item as Dictionary<string, object>;
                if (d == null) continue;
                list.Add(new RemoteDevice { Name = GetStr(d, "name"), Platform = GetStr(d, "platform") });
            }
            lock (stateLock) { OnlineDevices = list; }
            Notify();
        }

        static string GetStr(Dictionary<string, object> d, string key)
        {
            object v;
            return d.TryGetValue(key, out v) && v != null ? Convert.ToString(v) : "";
        }

        void SetError(string msg)
        {
            lock (stateLock) { State = SyncState.Error; ErrorText = msg; }
            Notify();
        }

        void Notify()
        {
            var h = Changed;
            if (h != null) h();
        }

        static void WaitCancel(CancellationToken ct, int ms)
        {
            try { ct.WaitHandle.WaitOne(ms); } catch (Exception) { }
        }

        void MarkHash(string hash)
        {
            if (string.IsNullOrEmpty(hash)) return;
            lock (dedupLock)
            {
                DateTime now = DateTime.UtcNow;
                recentHashes[hash] = now;
                var expired = recentHashes.Where(kv => (now - kv.Value).TotalSeconds > 20).Select(kv => kv.Key).ToList();
                foreach (var k in expired) recentHashes.Remove(k);
            }
        }

        bool SeenRecently(string hash)
        {
            if (string.IsNullOrEmpty(hash)) return false;
            lock (dedupLock)
            {
                DateTime ts;
                return recentHashes.TryGetValue(hash, out ts) && (DateTime.UtcNow - ts).TotalSeconds <= 15;
            }
        }

        public static string ComputeHash(string kind, byte[] raw)
        {
            using (var sha = SHA256.Create())
            {
                byte[] prefix = Encoding.UTF8.GetBytes(kind + "\0");
                byte[] combined = new byte[prefix.Length + raw.Length];
                Buffer.BlockCopy(prefix, 0, combined, 0, prefix.Length);
                Buffer.BlockCopy(raw, 0, combined, prefix.Length, raw.Length);
                byte[] sum = sha.ComputeHash(combined);
                var sb = new StringBuilder(sum.Length * 2);
                foreach (byte b in sum) sb.Append(b.ToString("x2"));
                return sb.ToString();
            }
        }

        static HttpWebRequest CreateRequest(string url, string method, string token, int timeoutMs)
        {
            var req = (HttpWebRequest)WebRequest.Create(url);
            req.Method = method;
            req.Timeout = timeoutMs;
            req.KeepAlive = true;
            req.Headers["Authorization"] = "Bearer " + token;
            if (IsDirectLANOrTailscale(req.RequestUri))
                req.Proxy = null;
            return req;
        }

        static bool IsDirectLANOrTailscale(Uri uri)
        {
            if (uri == null) return false;
            string host = uri.Host.ToLowerInvariant();
            if (host == "localhost" || host == "127.0.0.1" || host == "::1" || host.EndsWith(".local") || host.EndsWith(".ts.net"))
                return true;
            IPAddress ip;
            if (!IPAddress.TryParse(host, out ip) || ip.AddressFamily != AddressFamily.InterNetwork) return false;
            byte[] b = ip.GetAddressBytes();
            if (b[0] == 10 || b[0] == 127) return true;
            if (b[0] == 192 && b[1] == 168) return true;
            if (b[0] == 172 && b[1] >= 16 && b[1] <= 31) return true;
            if (b[0] == 100 && b[1] >= 64 && b[1] <= 127) return true;
            return false;
        }

        public static string GenerateToken()
        {
            byte[] b = new byte[16];
            using (var rng = new RNGCryptoServiceProvider()) rng.GetBytes(b);
            var sb = new StringBuilder(32);
            foreach (byte x in b) sb.Append(x.ToString("x2"));
            return sb.ToString();
        }

        public static string DetectTailscaleIP()
        {
            foreach (var ip in LocalIPv4s())
            {
                var b = ip.GetAddressBytes();
                if (b[0] == 100 && b[1] >= 64 && b[1] <= 127) return ip.ToString();
            }
            return null;
        }

        public static string DetectLANIP()
        {
            foreach (var ip in LocalIPv4s())
            {
                var b = ip.GetAddressBytes();
                if ((b[0] == 192 && b[1] == 168) || b[0] == 10) return ip.ToString();
            }
            return null;
        }

        static List<IPAddress> LocalIPv4s()
        {
            var list = new List<IPAddress>();
            try
            {
                foreach (var ni in NetworkInterface.GetAllNetworkInterfaces())
                {
                    if (ni.OperationalStatus != OperationalStatus.Up) continue;
                    foreach (var ua in ni.GetIPProperties().UnicastAddresses)
                    {
                        if (ua.Address.AddressFamily == AddressFamily.InterNetwork && !IPAddress.IsLoopback(ua.Address))
                            list.Add(ua.Address);
                    }
                }
            }
            catch (Exception) { }
            return list;
        }
    }

    /// Lightweight zero-admin TcpListener HTTP+SSE hub for Windows Host Mode.
    sealed class LocalWindowsHub
    {
        readonly int port;
        readonly string token;
        readonly JavaScriptSerializer json = new JavaScriptSerializer { MaxJsonLength = 24 * 1024 * 1024 };
        readonly object syncLock = new object();
        readonly List<StoredEntry> history = new List<StoredEntry>();
        readonly List<Sub> subs = new List<Sub>();
        const long MaxHistoryBytes = 48L * 1024 * 1024;
        long totalHistoryBytes;
        TcpListener listener;
        volatile bool running;
        long nextId;

        sealed class StoredEntry
        {
            public long Id;
            public Dictionary<string, object> Item;
            public byte[] Raw;
            public string Kind;
            public string Mime;
            public string Hash;
            public string Device;
            public string DeviceId;
            public DateTime CreatedAt;
        }

        sealed class Sub
        {
            public TcpClient Client;
            public Stream Stream;
            public string Device;
            public string DeviceId;
            public string Platform;
            public string ConnectedAt;
            public bool MetaOnly;
        }

        public LocalWindowsHub(int port, string token)
        {
            this.port = port;
            this.token = token;
        }

        public bool Start()
        {
            try
            {
                listener = new TcpListener(IPAddress.Any, port);
                listener.Start();
                running = true;
                new Thread(AcceptLoop) { IsBackground = true, Name = "LocalWinHubAccept" }.Start();
                new Thread(PingLoop) { IsBackground = true, Name = "LocalWinHubPing" }.Start();
                return true;
            }
            catch (Exception) { return false; }
        }

        public void Stop()
        {
            running = false;
            try { if (listener != null) listener.Stop(); } catch (Exception) { }
            lock (syncLock)
            {
                foreach (var s in subs) { try { s.Client.Close(); } catch (Exception) { } }
                subs.Clear();
            }
        }

        void AcceptLoop()
        {
            while (running)
            {
                try
                {
                    var client = listener.AcceptTcpClient();
                    ThreadPool.QueueUserWorkItem(_ => HandleClient(client));
                }
                catch (Exception) { if (!running) break; }
            }
        }

        void PingLoop()
        {
            while (running)
            {
                Thread.Sleep(20000);
                if (!running) break;
                SendAll(": ping\n\n");
            }
        }

        void HandleClient(TcpClient client)
        {
            bool keepOpen = false;
            try
            {
                client.ReceiveTimeout = 10000;
                var stream = client.GetStream();
                byte[] headerBytes;
                byte[] extra;
                if (!ReadHeaders(stream, out headerBytes, out extra)) return;

                string headerText = Encoding.UTF8.GetString(headerBytes);
                string[] lines = headerText.Split(new[] { "\r\n" }, StringSplitOptions.None);
                if (lines.Length == 0) return;
                string[] reqParts = lines[0].Split(' ');
                if (reqParts.Length < 2) return;
                string method = reqParts[0].ToUpperInvariant();
                string target = reqParts[1];

                var headers = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
                for (int i = 1; i < lines.Length; i++)
                {
                    int idx = lines[i].IndexOf(':');
                    if (idx > 0) headers[lines[i].Substring(0, idx).Trim()] = lines[i].Substring(idx + 1).Trim();
                }

                string path = target;
                var query = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
                int qIdx = target.IndexOf('?');
                if (qIdx >= 0)
                {
                    path = target.Substring(0, qIdx);
                    foreach (var kv in target.Substring(qIdx + 1).Split('&'))
                    {
                        int eq = kv.IndexOf('=');
                        if (eq > 0) query[kv.Substring(0, eq)] = Uri.UnescapeDataString(kv.Substring(eq + 1));
                    }
                }

                if (path == "/api/health")
                {
                    WriteResp(stream, "200 OK", "application/json", Encoding.UTF8.GetBytes("{\"ok\":true}"));
                    return;
                }
                if (path == "/")
                {
                    WriteResp(stream, "200 OK", "text/html; charset=utf-8", Encoding.UTF8.GetBytes(MiniHTML));
                    return;
                }
                if (!Authorized(headers, query))
                {
                    WriteResp(stream, "401 Unauthorized", "text/plain", Encoding.UTF8.GetBytes("unauthorized"));
                    return;
                }

                int contentLen = 0;
                string clStr;
                if (headers.TryGetValue("Content-Length", out clStr))
                {
                    if (!int.TryParse(clStr, out contentLen) || contentLen < 0)
                    {
                        WriteResp(stream, "400 Bad Request", "text/plain", Encoding.UTF8.GetBytes("bad content-length"));
                        return;
                    }
                }
                if (contentLen > 16 * 1024 * 1024) { WriteResp(stream, "413 Payload Too Large", "text/plain", Encoding.UTF8.GetBytes("too large")); return; }

                byte[] body = new byte[contentLen];
                int copied = Math.Min(extra.Length, contentLen);
                if (copied > 0) Buffer.BlockCopy(extra, 0, body, 0, copied);
                int off = copied;
                while (off < contentLen)
                {
                    int r = stream.Read(body, off, contentLen - off);
                    if (r <= 0) break;
                    off += r;
                }

                if (method == "GET" && path == "/api/devices")
                {
                    WriteResp(stream, "200 OK", "application/json", Encoding.UTF8.GetBytes(json.Serialize(DevicesList())));
                }
                else if (method == "GET" && path == "/api/history")
                {
                    List<object> list;
                    lock (syncLock) { list = history.Select(h => (object)h.Item).ToList(); }
                    WriteResp(stream, "200 OK", "application/json", Encoding.UTF8.GetBytes(json.Serialize(list)));
                }
                else if (method == "GET" && path == "/api/clip")
                {
                    StoredEntry latest;
                    lock (syncLock) { latest = history.FirstOrDefault(); }
                    if (latest == null) WriteResp(stream, "204 No Content", "text/plain", new byte[0]);
                    else if (query.ContainsKey("raw") && query["raw"] == "1") WriteResp(stream, "200 OK", latest.Mime, latest.Raw);
                    else WriteResp(stream, "200 OK", "application/json", Encoding.UTF8.GetBytes(SerializeEntry(latest, false)));
                }
                else if (method == "GET" && path.StartsWith("/api/history/") && path.EndsWith("/raw"))
                {
                    string idStr = path.Substring("/api/history/".Length);
                    idStr = idStr.Substring(0, idStr.Length - "/raw".Length);
                    long wantId;
                    StoredEntry found = null;
                    if (long.TryParse(idStr, out wantId))
                    {
                        lock (syncLock) { found = history.FirstOrDefault(h => h.Id == wantId); }
                    }
                    if (found == null) WriteResp(stream, "404 Not Found", "text/plain", Encoding.UTF8.GetBytes("not found"));
                    else WriteResp(stream, "200 OK", found.Mime, found.Raw);
                }
                else if (method == "POST" && path == "/api/clip")
                {
                    HandlePost(stream, headers, body);
                }
                else if (method == "GET" && path == "/api/events")
                {
                    keepOpen = true;
                    client.ReceiveTimeout = Timeout.Infinite;
                    client.SendTimeout = 5000;
                    HandleSSE(client, stream, headers, query);
                }
                else
                {
                    WriteResp(stream, "404 Not Found", "text/plain", Encoding.UTF8.GetBytes("not found"));
                }
            }
            catch (Exception) { }
            finally
            {
                if (!keepOpen) { try { client.Close(); } catch (Exception) { } }
            }
        }

        string SerializeEntry(StoredEntry entry, bool metaOnly)
        {
            if (metaOnly || entry.Kind != "image") return json.Serialize(entry.Item);
            var copy = new Dictionary<string, object>(entry.Item);
            copy["data_base64"] = Convert.ToBase64String(entry.Raw);
            return json.Serialize(copy);
        }

        void HandlePost(Stream stream, Dictionary<string, string> headers, byte[] body)
        {
            string ct = headers.ContainsKey("Content-Type") ? headers["Content-Type"].ToLowerInvariant() : "";
            string dev = headers.ContainsKey("X-Device") ? headers["X-Device"] : "unknown";
            string devId = headers.ContainsKey("X-Device-Id") ? headers["X-Device-Id"] : "";
            string plat = headers.ContainsKey("X-Platform") ? headers["X-Platform"] : "other";
            string kind = "text";
            string mime = "text/plain; charset=utf-8";
            byte[] raw = body;

            if (ct.StartsWith("application/json"))
            {
                var obj = json.Deserialize<Dictionary<string, object>>(Encoding.UTF8.GetString(body));
                if (obj != null)
                {
                    if (obj.ContainsKey("device") && obj["device"] != null) dev = Convert.ToString(obj["device"]);
                    if (obj.ContainsKey("device_id") && obj["device_id"] != null) devId = Convert.ToString(obj["device_id"]);
                    if (obj.ContainsKey("platform") && obj["platform"] != null) plat = Convert.ToString(obj["platform"]);
                    kind = obj.ContainsKey("kind") && obj["kind"] != null ? Convert.ToString(obj["kind"]) : (obj.ContainsKey("data_base64") ? "image" : "text");
                    if (kind == "image" && obj.ContainsKey("data_base64"))
                    {
                        raw = Convert.FromBase64String(Convert.ToString(obj["data_base64"]));
                        mime = obj.ContainsKey("mime") && obj["mime"] != null ? Convert.ToString(obj["mime"]) : "image/png";
                    }
                    else
                    {
                        kind = "text";
                        raw = Encoding.UTF8.GetBytes(obj.ContainsKey("text") && obj["text"] != null ? Convert.ToString(obj["text"]) : "");
                    }
                }
            }
            else if (ct.StartsWith("image/"))
            {
                kind = "image";
                mime = ct.Split(';')[0];
            }

            if (raw.Length == 0) { WriteResp(stream, "400 Bad Request", "text/plain", Encoding.UTF8.GetBytes("empty")); return; }
            string hash = CrossSync.ComputeHash(kind, raw);

            StoredEntry entry;
            lock (syncLock)
            {
                if (history.Count > 0 && history[0].Hash == hash)
                {
                    WriteResp(stream, "200 OK", "application/json", Encoding.UTF8.GetBytes("{\"duplicate\":true}"));
                    return;
                }
                nextId++;
                var now = DateTime.UtcNow;
                var item = new Dictionary<string, object>
                {
                    { "id", nextId },
                    { "kind", kind },
                    { "mime", mime },
                    { "size_bytes", raw.Length },
                    { "hash", hash },
                    { "device", dev },
                    { "platform", plat },
                    { "created_at", now.ToString("o") }
                };
                if (!string.IsNullOrEmpty(devId)) item["device_id"] = devId;
                if (kind == "text") item["text"] = Encoding.UTF8.GetString(raw);

                entry = new StoredEntry
                {
                    Id = nextId,
                    Item = item,
                    Raw = raw,
                    Kind = kind,
                    Mime = mime,
                    Hash = hash,
                    Device = dev,
                    DeviceId = devId,
                    CreatedAt = now
                };
                history.Insert(0, entry);
                totalHistoryBytes += raw.Length;
                while (history.Count > 30 || (history.Count > 1 && totalHistoryBytes > MaxHistoryBytes))
                {
                    var dropped = history[history.Count - 1];
                    history.RemoveAt(history.Count - 1);
                    totalHistoryBytes -= dropped.Raw.Length;
                }
            }
            BroadcastClip(entry);
            WriteResp(stream, "200 OK", "application/json", Encoding.UTF8.GetBytes("{\"duplicate\":false}"));
        }

        void HandleSSE(TcpClient client, Stream stream, Dictionary<string, string> headers, Dictionary<string, string> query)
        {
            string dev = query.ContainsKey("device") ? query["device"] : (headers.ContainsKey("X-Device") ? headers["X-Device"] : "client");
            string devId = query.ContainsKey("device_id") ? query["device_id"] : (headers.ContainsKey("X-Device-Id") ? headers["X-Device-Id"] : "");
            string plat = query.ContainsKey("platform") ? query["platform"] : (headers.ContainsKey("X-Platform") ? headers["X-Platform"] : "other");
            bool metaOnly = query.ContainsKey("meta") && query["meta"] == "1";
            long since = 0;
            if (query.ContainsKey("since")) long.TryParse(query["since"], out since);
            var sub = new Sub { Client = client, Stream = stream, Device = dev, DeviceId = devId, Platform = plat, ConnectedAt = DateTime.UtcNow.ToString("o"), MetaOnly = metaOnly };

            List<Dictionary<string, string>> devs;
            long latestId;
            string catchUpJson = null;
            lock (syncLock)
            {
                latestId = nextId;
                var preview = new List<Sub>(subs) { sub };
                devs = DevicesListFrom(preview);
                if (since > 0 && history.Count > 0)
                {
                    var latest = history[0];
                    if (latest.Id > since && (DateTime.UtcNow - latest.CreatedAt).TotalMinutes <= 10)
                    {
                        bool isSelf = !string.IsNullOrEmpty(devId) && !string.IsNullOrEmpty(latest.DeviceId)
                            ? string.Equals(devId, latest.DeviceId, StringComparison.OrdinalIgnoreCase)
                            : string.Equals(dev, latest.Device, StringComparison.OrdinalIgnoreCase);
                        if (!isSelf) catchUpJson = SerializeEntry(latest, metaOnly);
                    }
                }
            }
            // Write HTTP headers & ready BEFORE registering subscriber so broadcasts never interleave before headers
            string ready = json.Serialize(new Dictionary<string, object> { { "clients", devs.Count }, { "devices", devs }, { "latest_id", latestId } });
            string headStr = "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nCache-Control: no-cache\r\nConnection: keep-alive\r\n\r\nevent: ready\ndata: " + ready + "\n\n";
            if (!string.IsNullOrEmpty(catchUpJson)) headStr += "event: clip\ndata: " + catchUpJson + "\n\n";
            byte[] head = Encoding.UTF8.GetBytes(headStr);
            try { lock (sub) { stream.Write(head, 0, head.Length); stream.Flush(); } }
            catch (Exception) { try { client.Close(); } catch (Exception) { } return; }

            lock (syncLock)
            {
                subs.Add(sub);
                devs = DevicesListLocked();
            }
            SendAll("event: devices\ndata: " + json.Serialize(devs) + "\n\n");
        }

        List<Dictionary<string, string>> DevicesList()
        {
            lock (syncLock) { return DevicesListLocked(); }
        }

        List<Dictionary<string, string>> DevicesListLocked()
        {
            return DevicesListFrom(subs);
        }

        static List<Dictionary<string, string>> DevicesListFrom(IEnumerable<Sub> source)
        {
            var map = new Dictionary<string, Dictionary<string, string>>();
            foreach (var s in source)
            {
                string key = !string.IsNullOrEmpty(s.DeviceId) ? s.DeviceId : s.Device;
                var rec = new Dictionary<string, string> { { "name", s.Device }, { "platform", s.Platform }, { "connected_at", s.ConnectedAt } };
                if (!string.IsNullOrEmpty(s.DeviceId)) rec["id"] = s.DeviceId;
                map[key] = rec;
            }
            return map.Values.OrderBy(d => d["name"]).ToList();
        }

        void RemoveSub(Sub s)
        {
            List<Dictionary<string, string>> devs = null;
            lock (syncLock)
            {
                if (subs.Remove(s)) devs = DevicesListLocked();
            }
            try { s.Client.Close(); } catch (Exception) { }
            if (devs != null) SendAll("event: devices\ndata: " + json.Serialize(devs) + "\n\n");
        }

        void BroadcastClip(StoredEntry entry)
        {
            List<Sub> snap;
            lock (syncLock) { snap = subs.ToList(); }
            byte[] metaBytes = null;
            byte[] fullBytes = null;
            foreach (var s in snap)
            {
                byte[] frame;
                if (s.MetaOnly || entry.Kind != "image")
                {
                    if (metaBytes == null) metaBytes = Encoding.UTF8.GetBytes("event: clip\ndata: " + SerializeEntry(entry, true) + "\n\n");
                    frame = metaBytes;
                }
                else
                {
                    if (fullBytes == null) fullBytes = Encoding.UTF8.GetBytes("event: clip\ndata: " + SerializeEntry(entry, false) + "\n\n");
                    frame = fullBytes;
                }
                var target = s;
                ThreadPool.QueueUserWorkItem(_ => SendToSub(target, frame));
            }
        }

        void SendAll(string text)
        {
            byte[] bytes = Encoding.UTF8.GetBytes(text);
            List<Sub> snap;
            lock (syncLock) { snap = subs.ToList(); }
            foreach (var s in snap)
            {
                var target = s;
                ThreadPool.QueueUserWorkItem(_ => SendToSub(target, bytes));
            }
        }

        void SendToSub(Sub s, byte[] bytes)
        {
            try { lock (s) { s.Stream.Write(bytes, 0, bytes.Length); s.Stream.Flush(); } }
            catch (Exception) { RemoveSub(s); }
        }

        bool Authorized(Dictionary<string, string> headers, Dictionary<string, string> query)
        {
            string got = "";
            if (headers.ContainsKey("Authorization") && headers["Authorization"].StartsWith("Bearer "))
                got = headers["Authorization"].Substring(7).Trim();
            else if (headers.ContainsKey("X-Token")) got = headers["X-Token"].Trim();
            else if (query.ContainsKey("token")) got = query["token"].Trim();
            return !string.IsNullOrEmpty(got) && got == token;
        }

        static bool ReadHeaders(Stream s, out byte[] headerBytes, out byte[] extra)
        {
            headerBytes = null; extra = null;
            var ms = new MemoryStream();
            byte[] buf = new byte[4096];
            while (ms.Length < 65536)
            {
                int r = s.Read(buf, 0, buf.Length);
                if (r <= 0) return false;
                ms.Write(buf, 0, r);
                byte[] all = ms.ToArray();
                for (int i = 0; i <= all.Length - 4; i++)
                {
                    if (all[i] == 13 && all[i + 1] == 10 && all[i + 2] == 13 && all[i + 3] == 10)
                    {
                        headerBytes = new byte[i];
                        Buffer.BlockCopy(all, 0, headerBytes, 0, i);
                        int rem = all.Length - (i + 4);
                        extra = new byte[rem];
                        if (rem > 0) Buffer.BlockCopy(all, i + 4, extra, 0, rem);
                        return true;
                    }
                }
            }
            return false;
        }

        static void WriteResp(Stream s, string status, string ct, byte[] body)
        {
            byte[] head = Encoding.UTF8.GetBytes("HTTP/1.1 " + status + "\r\nContent-Type: " + ct + "\r\nContent-Length: " + body.Length + "\r\nConnection: close\r\n\r\n");
            s.Write(head, 0, head.Length);
            if (body.Length > 0) s.Write(body, 0, body.Length);
            s.Flush();
        }

        const string MiniHTML = "<!doctype html><html lang='zh-CN'><head><meta charset='utf-8'><meta name='viewport' content='width=device-width,initial-scale=1'><title>Clipline Sync</title><style>body{font-family:sans-serif;max-width:680px;margin:0 auto;padding:16px;background:#111;color:#eee}textarea{width:100%;padding:10px;border-radius:10px;border:1px solid #333;background:#1c1f26;color:#fff;box-sizing:border-box}button{padding:10px 14px;border-radius:10px;border:0;background:#4c8dff;color:#fff;font-weight:600;margin:6px 6px 6px 0}.card{background:#1c1f26;border-radius:12px;padding:12px;margin:10px 0;white-space:pre-wrap}</style></head><body><h3>Clipline 跨设备剪贴板</h3><textarea id='t' rows='3' placeholder='输入文字发送...'></textarea><div><button onclick='send()'>发送</button><button onclick='pull()'>复制最新</button></div><div id='h'></div><script>const hp=new URLSearchParams(location.hash.replace(/^#/,'')),sp=new URLSearchParams(location.search),pt=hp.get('pair')||sp.get('pair');if(pt){localStorage.cs_tok=pt;history.replaceState(null,'',location.pathname);}const tok=localStorage.cs_tok||prompt('Token')||'';localStorage.cs_tok=tok;const esc=s=>String(s||'').replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;');const hdr={'Authorization':'Bearer '+tok,'X-Device':'mobile-web','X-Platform':'web'};async function load(){const r=await fetch('api/history',{headers:hdr});if(!r.ok)return;const a=await r.json();document.getElementById('h').innerHTML=a.map(x=>'<div class=card><small>'+esc(x.device)+'</small><br>'+(x.kind==='text'?esc(x.text):'[图片]')+'</div>').join('');}async function send(){const v=document.getElementById('t').value;if(!v)return;await fetch('api/clip',{method:'POST',headers:hdr,body:v});document.getElementById('t').value='';load();}async function pull(){const r=await fetch('api/clip?raw=1',{headers:hdr});if(r.ok){const s=await r.text();navigator.clipboard&&navigator.clipboard.writeText(s);alert('已获取: '+s.slice(0,60));}}load();new EventSource('api/events?token='+encodeURIComponent(tok)+'&device=mobile-web&platform=web').addEventListener('clip',load);</script></body></html>";
    }
}
