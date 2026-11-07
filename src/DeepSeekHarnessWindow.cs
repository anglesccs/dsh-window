using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.Globalization;
using System.IO;
using System.Net;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;
using System.Web.Script.Serialization;
using System.Windows.Forms;
using Microsoft.Win32;
using Microsoft.Web.WebView2.Core;
using Microsoft.Web.WebView2.WinForms;

[assembly: AssemblyTitle("DeepSeek Harness")]
[assembly: AssemblyDescription("DeepSeek Harness standalone window (WebView2)")]
[assembly: AssemblyCompany("Community project, not affiliated with DeepSeek")]
[assembly: AssemblyProduct("DeepSeek Harness Window")]
[assembly: AssemblyVersion("1.4.2.0")]
[assembly: AssemblyFileVersion("1.4.2.0")]

internal static class Program
{
    private const string AppTitle = "DeepSeek Harness";
    private const string AppVersion = "1.4.2";
    private const string ConfigFileName = "dsh-window.config.json";
    private const string DefaultHost = "127.0.0.1";
    private const int DefaultPort = 3080;
    private const string DefaultSessionSelector = "[class*='_running']";
    private const int DefaultSessionIntervalMs = 2000;
    private const int MinSessionIntervalMs = 500;
    private const int MaxSessionIntervalMs = 30000;
    private const string PickerPatch =
        "- id: directory-picker\r\n" +
        "  disabled: true\r\n" +
        "- insert:\r\n" +
        "    - id: directory-picker-browse\r\n" +
        "      name: '@deepseek-ai/dsh-host-directory-picker-browse'\r\n" +
        "    - id: directory-picker-browse-ui\r\n" +
        "      name: '@deepseek-ai/dsh-client-ui-directory-picker-browse'\r\n";

    private static LauncherConfig config;
    private static ResolvedPaths paths;
    private static string patchPath;
    private static string appUrl;
    private static Process spawnedServer;
    private static Mutex singleInstance;
    private static bool urlValid = true;
    private static bool configInvalid;
    private static bool logAlways;

    internal static readonly string LogPath = Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
        "DeepSeekHarnessWindow", "launcher.log");

    [STAThread]
    private static int Main(string[] args)
    {
        // High-DPI: the embedded manifest (PerMonitorV2) is the primary
        // mechanism; this runtime fallback covers builds without a manifest.
        EnableHighDpi();
        // GitHub API requires TLS 1.2+; the .NET Framework default is lower.
        ServicePointManager.SecurityProtocol = SecurityProtocolType.Tls12;
        try
        {
            bool checkOnly = HasFlag(args, "--check");
            bool noWindow = HasFlag(args, "--no-window") || HasFlag(args, "--no-open");
            bool install = HasFlag(args, "--install");
            bool uninstall = HasFlag(args, "--uninstall");
            bool notifyTest = HasFlag(args, "--notify-test");
            // Its lines must land in the log even when logFile is off, and even
            // when the failure happens before the config is loaded.
            logAlways = notifyTest;

            string appDir = AppDomain.CurrentDomain.BaseDirectory;
            string localAppData = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);

            // Installer mode runs before any runtime resolution so it also
            // works on machines without Node/DSH installed. --check always
            // wins: it must stay headless (no dialogs at all).
            if (install && !checkOnly)
                return RunInstall(appDir) ? 0 : 1;
            if (uninstall && !checkOnly)
                return RunUninstall() ? 0 : 1;

            // Configuration first: the mode it selects decides whether the
            // local Node/DSH runtime is needed at all.
            string configPath = Path.Combine(appDir, ConfigFileName);
            config = LoadConfig(configPath);
            appUrl = BuildAppUrl(config, out urlValid);
            // In external mode the effective target is the URL, so report
            // hostIsLocal for that host instead of the unused `host` key.
            if (IsExternalMode(config))
                config.HostIsLocal = UrlHostIsLocal(appUrl);
            FlushConfigWarnings();
            patchPath = Path.Combine(localAppData, "DeepSeekHarnessLauncher", "directory-picker.patch.yml");

            // Diagnostic mode wins over every other headless mode: it needs the
            // config only for the log sink, never the server or a window.
            if (notifyTest)
                return RunNotifyTest();

            if (checkOnly)
                return RunCheck(configPath, args);

            if (IsExternalMode(config))
            {
                Log("start, url=" + appUrl + ", mode=external");
            }
            else
            {
                if (!config.HostIsLocal)
                {
                    Log("refuse to spawn: host " + config.Host + " is not a local address");
                    if (noWindow)
                        return 3;
                    return RunWindow(null, false);
                }
                // Local mode needs the runtime only when something has to be
                // started; an already-running service needs no local Node.
                bool alreadyOnline = IsOnline(appUrl, 1200);
                try
                {
                    paths = ResolvePaths(appDir, localAppData);
                }
                catch (Exception error)
                {
                    Log("runtime resolution failed: " + error.Message);
                    if (!alreadyOnline)
                    {
                        if (noWindow)
                            return 3;
                        MessageBox.Show(error.Message, AppTitle, MessageBoxButtons.OK, MessageBoxIcon.Error);
                        return 1;
                    }
                }
                Log("start, url=" + appUrl + ", mode=local, runtime=" + (paths != null) +
                    ", online=" + alreadyOnline);

                // The picker overlay is only consumed by the local spawn.
                if (paths != null)
                {
                    Directory.CreateDirectory(Path.GetDirectoryName(patchPath));
                    File.WriteAllText(patchPath, PickerPatch);
                }
            }

            bool serverReady = EnsureServer();

            if (noWindow)
                return serverReady ? 0 : 3;

            return RunWindow(spawnedServer, serverReady);
        }
        catch (Exception error)
        {
            if (HasFlag(args, "--notify-test"))
            {
                // Diagnostic entry: report and stay successful.
                Log("notify test failed: " + error.Message);
                return 0;
            }
            if (HasFlag(args, "--check") || HasFlag(args, "--no-window") || HasFlag(args, "--no-open"))
            {
                // Headless modes must never block on a modal dialog.
                Log("headless failure: " + error.Message);
                return HasFlag(args, "--check") ? 2 : 1;
            }
            MessageBox.Show(error.Message, AppTitle, MessageBoxButtons.OK, MessageBoxIcon.Error);
            return 1;
        }
    }

    /// <summary>Shows the main window (single instance) and runs the message loop.</summary>
    private static int RunWindow(Process ownedServer, bool serverReady)
    {
        bool createdNew;
        singleInstance = new Mutex(true, @"Local\DeepSeekHarnessWindow.v2", out createdNew);
        if (!createdNew)
        {
            FocusExistingInstance();
            return 0;
        }

        Application.EnableVisualStyles();
        Application.SetCompatibleTextRenderingDefault(false);
        // Closing may only stop a server this process owns and only in local mode.
        bool canKill = config.KillServerOnClose && !IsExternalMode(config) && config.HostIsLocal;
        Application.Run(new MainForm(ownedServer, appUrl, serverReady, canKill,
            config.CloseToTray, IsExternalMode(config)));
        return 0;
    }

    internal static void Log(string message)
    {
        // --notify-test is a diagnostic entry: its lines must reach the log even
        // when the user's config keeps logFile off, otherwise a failure there
        // leaves no trace at all.
        if (!logAlways && (config == null || !config.LogFile))
            return;
        try
        {
            Directory.CreateDirectory(Path.GetDirectoryName(LogPath));
            File.AppendAllText(LogPath,
                DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss") + " " + message + Environment.NewLine,
                Encoding.UTF8);
        }
        catch
        {
        }
    }

    // ---- High-DPI awareness ----
    // The embedded app.manifest declares PerMonitorV2; when a manifest is
    // present these calls fail with E_ACCESSDENIED and we keep the manifest
    // value. Without a manifest they promote the process so the window is
    // not bitmap-stretched on scaled displays (issue #1).

    private static readonly IntPtr DpiAwarenessContextPerMonitorV2 = new IntPtr(-4);

    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool SetProcessDpiAwarenessContext(IntPtr value);

    [DllImport("shcore.dll")]
    private static extern int SetProcessDpiAwareness(int value);

    [DllImport("user32.dll")]
    private static extern bool SetProcessDPIAware();

    private static void EnableHighDpi()
    {
        try
        {
            if (!SetProcessDpiAwarenessContext(DpiAwarenessContextPerMonitorV2))
            {
                try
                {
                    SetProcessDpiAwareness(2); // PROCESS_PER_MONITOR_DPI_AWARE
                }
                catch
                {
                    SetProcessDPIAware();
                }
            }
        }
        catch
        {
            try
            {
                SetProcessDPIAware();
            }
            catch
            {
                // Nothing left to try; the window will be virtualized.
            }
        }
    }

    /// <summary>Ensures the DSH server is online, starting it when needed.</summary>
    internal static bool EnsureServer()
    {
        if (IsOnline(appUrl, 1200))
            return true;
        // External mode never touches local processes.
        if (IsExternalMode(config) || !config.HostIsLocal || paths == null)
        {
            Log("server unreachable, not spawning (external mode / remote host / no runtime)");
            return false;
        }
        if (spawnedServer == null || spawnedServer.HasExited)
            spawnedServer = StartHarness();
        return WaitFor(appUrl, config.WaitTimeoutMs);
    }

    internal sealed class UpdateInfo
    {
        public string LatestVersion;
        public string ReleaseUrl;
    }

    /// <summary>Queries GitHub for the latest release of the community repo.</summary>
    internal static UpdateInfo CheckForUpdates()
    {
        try
        {
            string url = "https://api.github.com/repos/" + config.UpdateRepo + "/releases/latest";
            HttpWebRequest request = (HttpWebRequest)WebRequest.Create(url);
            request.Method = "GET";
            request.Timeout = 8000;
            request.ReadWriteTimeout = 8000;
            request.UserAgent = "DeepSeek-Harness-Window";
            using (HttpWebResponse response = (HttpWebResponse)request.GetResponse())
            using (StreamReader reader = new StreamReader(response.GetResponseStream(), Encoding.UTF8))
            {
                JavaScriptSerializer serializer = new JavaScriptSerializer();
                Dictionary<string, object> release =
                    serializer.Deserialize<Dictionary<string, object>>(reader.ReadToEnd());
                if (release == null || !release.ContainsKey("tag_name"))
                    return null;
                string tag = Convert.ToString(release["tag_name"]);
                Version latest = ParseVersion(tag);
                Version current = Assembly.GetExecutingAssembly().GetName().Version;
                if (latest != null && latest > current)
                {
                    return new UpdateInfo
                    {
                        LatestVersion = tag,
                        ReleaseUrl = release.ContainsKey("html_url") ? Convert.ToString(release["html_url"]) : ""
                    };
                }
            }
        }
        catch (Exception error)
        {
            Log("update check failed: " + error.Message);
        }
        return null;
    }

    private static Version ParseVersion(string tag)
    {
        if (string.IsNullOrEmpty(tag))
            return null;
        string value = tag.StartsWith("v", StringComparison.OrdinalIgnoreCase) ? tag.Substring(1) : tag;
        try
        {
            return new Version(value);
        }
        catch
        {
            return null;
        }
    }

    private static bool HasFlag(string[] args, string flag)
    {
        foreach (string arg in args)
        {
            if (string.Equals(arg, flag, StringComparison.OrdinalIgnoreCase))
                return true;
        }
        return false;
    }

    private static string GetArgValue(string[] args, string flag)
    {
        for (int i = 0; i < args.Length; i++)
        {
            string arg = args[i];
            if (string.Equals(arg, flag, StringComparison.OrdinalIgnoreCase))
                return i + 1 < args.Length ? args[i + 1] : "";
            if (arg.StartsWith(flag + "=", StringComparison.OrdinalIgnoreCase))
                return arg.Substring(flag.Length + 1);
        }
        return null;
    }

    // ---- headless --notify-test ----

    /// <summary>Diagnostic entry point: raises one balloon from a throwaway tray
    /// icon and pumps messages for a few seconds so the shell can render it.
    /// No window, no server, no spawn; always exits 0 so it stays scriptable on
    /// machines where Windows itself blocks notifications.</summary>
    private static int RunNotifyTest()
    {
        NotifyIcon icon = null;
        Icon image = null;
        bool ownImage = false;
        try
        {
            icon = new NotifyIcon();
            try
            {
                image = Icon.ExtractAssociatedIcon(Application.ExecutablePath);
                ownImage = image != null;
            }
            catch
            {
                // A missing exe icon must not stop the balloon from being asked for.
            }
            // The balloon needs some icon; the stock one keeps the request valid.
            if (image == null)
                image = SystemIcons.Application;
            icon.Icon = image;
            icon.Text = AppTitle;
            icon.Visible = true;
            icon.ShowBalloonTip(8000, AppTitle,
                "通知自测：能看到这条气泡说明程序侧和系统侧都正常。", ToolTipIcon.Info);
            Log("notify test: balloon requested");
            // /target:winexe has no message loop of its own here, and a balloon
            // needs a pump to reach the shell, so pump manually and bail out
            // after 10s no matter what.
            Stopwatch clock = Stopwatch.StartNew();
            while (clock.ElapsedMilliseconds < 10000)
            {
                Application.DoEvents();
                Thread.Sleep(50);
            }
            Log("notify test: done after " +
                clock.ElapsedMilliseconds.ToString(CultureInfo.InvariantCulture) + "ms");
        }
        catch (Exception error)
        {
            Log("notify test failed: " + error.Message);
        }
        finally
        {
            if (icon != null)
            {
                try
                {
                    icon.Visible = false;
                    icon.Dispose();
                }
                catch
                {
                }
            }
            // The extracted icon is ours; SystemIcons.Application is shared and
            // must not be disposed.
            if (ownImage)
            {
                try
                {
                    image.Dispose();
                }
                catch
                {
                }
            }
        }
        return 0;
    }

    // ---- headless --check ----

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool AttachConsole(int processId);

    /// <summary>Headless self-check: no window, no WebView2, no process spawn,
    /// no modal dialog. Exit 0 when ok, 2 otherwise.</summary>
    private static int RunCheck(string configPath, string[] args)
    {
        bool configFound = File.Exists(configPath);
        List<string> problems = new List<string>();
        bool runtimeAvailable = false;
        string nodeExe = "";
        string dshEntry = "";

        if (configInvalid)
            AddProblem(problems, "invalid-config");

        if (!urlValid)
            AddProblem(problems, "invalid-url");

        if (IsExternalMode(config))
        {
            // External mode never resolves the local runtime.
            if (urlValid && !IsOnline(appUrl, 2500))
                AddProblem(problems, "port-unreachable");
        }
        else if (!config.HostIsLocal)
        {
            // Spawning against a remote host can never bind; refuse instead of
            // launching a node process that is doomed to EADDRNOTAVAIL.
            AddProblem(problems, "refuse-remote-host-in-local-mode");
        }
        else
        {
            // Local mode is the only mode that resolves the runtime.
            bool online = urlValid && IsOnline(appUrl, 1500);
            try
            {
                ResolvedPaths resolved = ResolvePaths(
                    AppDomain.CurrentDomain.BaseDirectory,
                    Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData));
                runtimeAvailable = true;
                nodeExe = resolved.NodeExe;
                dshEntry = resolved.DshEntry;
            }
            catch
            {
                AddProblem(problems, "runtime-missing");
            }
            if (!online)
                AddProblem(problems, "port-unreachable");
        }

        bool ok = problems.Count == 0;
        Dictionary<string, object> report = new Dictionary<string, object>();
        report["version"] = AppVersion;
        report["serverMode"] = config.ServerMode;
        report["url"] = appUrl;
        report["configPath"] = configPath;
        report["configFound"] = configFound;
        Dictionary<string, object> runtime = new Dictionary<string, object>();
        runtime["available"] = runtimeAvailable;
        runtime["nodeExe"] = nodeExe;
        runtime["dshEntry"] = dshEntry;
        report["runtime"] = runtime;
        report["hostIsLocal"] = config.HostIsLocal;
        report["problems"] = problems;
        report["ok"] = ok;

        string json = new JavaScriptSerializer().Serialize(report);
        Log("check: ok=" + ok + ", problems=" + problems.Count);

        string outPath = GetArgValue(args, "--out");
        if (!string.IsNullOrEmpty(outPath))
        {
            try
            {
                string full = Path.GetFullPath(outPath);
                string dir = Path.GetDirectoryName(full);
                if (!string.IsNullOrEmpty(dir))
                    Directory.CreateDirectory(dir);
                // UTF-8 without BOM: File.WriteAllText(UTF8Encoding(false)).
                File.WriteAllText(full, json, new UTF8Encoding(false));
            }
            catch (Exception error)
            {
                Log("check report write failed: " + error.Message);
            }
        }

        WriteConsole(report);
        return ok ? 0 : 2;
    }

    private static void AddProblem(List<string> problems, string problem)
    {
        if (!problems.Contains(problem))
            problems.Add(problem);
    }

    /// <summary>Attaches to the parent console (the exe is /target:winexe) and
    /// prints the report; silently does nothing when there is no console.</summary>
    private static void WriteConsole(Dictionary<string, object> report)
    {
        StringBuilder text = new StringBuilder();
        text.AppendLine("dsh-window " + report["version"] + " check");
        text.AppendLine("  serverMode : " + report["serverMode"]);
        text.AppendLine("  url        : " + report["url"]);
        text.AppendLine("  config     : " + report["configPath"] +
            (Convert.ToBoolean(report["configFound"]) ? "" : " (missing)"));
        text.AppendLine("  runtime    : " + Convert.ToBoolean(
            ((Dictionary<string, object>)report["runtime"])["available"]));
        text.AppendLine("  ok         : " + report["ok"]);
        List<string> problems = report["problems"] as List<string>;
        if (problems != null && problems.Count > 0)
            text.AppendLine("  problems   : " + string.Join(", ", problems.ToArray()));

        // A winexe starts without a console; attach to the parent's when there
        // is one. AttachConsole returns false when already attached or when
        // there is no parent console at all.
        AttachConsole(-1);
        try
        {
            Console.Out.Write(text.ToString());
            Console.Out.Flush();
        }
        catch
        {
            try
            {
                // Stdout is unusable for a winexe; fall back to the console
                // device itself (name concatenated to avoid a dollar-quote).
                string consoleDevice = "CONOUT" + (char)36;
                using (FileStream device = new FileStream(consoleDevice, FileMode.Open, FileAccess.Write))
                using (StreamWriter console = new StreamWriter(device, new UTF8Encoding(false)))
                {
                    console.NewLine = "\r\n";
                    console.Write(text.ToString());
                    console.Flush();
                }
            }
            catch
            {
                // No console at all: stay silent, the JSON file is authoritative.
            }
        }
    }

    private sealed class ResolvedPaths
    {
        public string NodeExe;
        public string DshEntry;
        public string GitCmd;
    }

    private static ResolvedPaths ResolvePaths(string appDir, string localAppData)
    {
        string portableNode = Path.Combine(appDir, "runtime", "node", "node.exe");
        string portableDsh = Path.Combine(appDir, "runtime", "node_modules", "@deepseek-ai", "dsh", "lib", "bin.js");
        string portableGit = Path.Combine(appDir, "runtime", "git", "cmd");

        string sysNodeRoot = Path.Combine(localAppData, "Programs", "nodejs");
        string sysNode = Path.Combine(sysNodeRoot, "node.exe");
        string sysDsh = Path.Combine(sysNodeRoot, "node_modules", "@deepseek-ai", "dsh", "lib", "bin.js");
        string sysGit = Path.Combine(localAppData, "Programs", "Git", "cmd");

        if (File.Exists(portableNode) && File.Exists(portableDsh))
            return new ResolvedPaths { NodeExe = portableNode, DshEntry = portableDsh, GitCmd = portableGit };
        if (File.Exists(sysNode) && File.Exists(sysDsh))
            return new ResolvedPaths { NodeExe = sysNode, DshEntry = sysDsh, GitCmd = sysGit };

        throw new InvalidOperationException(
            "找不到 DeepSeek Harness 运行环境。\n\n" +
            "便携版：请确认本程序同目录下 runtime 文件夹完整（runtime\\node、runtime\\node_modules）。\n" +
            "系统版：请先安装 Node.js，再运行 npm.cmd install -g @deepseek-ai/dsh");
    }

    private sealed class LauncherConfig
    {
        public string Host = DefaultHost;
        public int Port = DefaultPort;
        public int WaitTimeoutMs = 30000;
        public bool KillServerOnClose = true;
        public string PermissionMode = "danger-full-access";
        public bool CheckUpdates = true;
        public string UpdateRepo = "anglesccs/dsh-window";
        public bool CloseToTray = false;
        public bool LogFile = false;
        public string ServerMode = "local";
        public string ExternalUrl = "";
        public bool HostIsLocal = true;
        public bool SessionNotify = false;
        public string SessionRunningSelector = DefaultSessionSelector;
        public int SessionNotifyIntervalMs = DefaultSessionIntervalMs;
    }

    private static readonly List<string> configWarnings = new List<string>();

    /// <summary>Emits warnings collected while reading the config (before the
    /// log sink is usable they are simply kept).</summary>
    private static void FlushConfigWarnings()
    {
        foreach (string warning in configWarnings)
            Log("config warning: " + warning);
        configWarnings.Clear();
    }

    /// <summary>True when the host resolves to this machine, so spawning a
    /// local `dsh --host &lt;host&gt;` can actually bind.</summary>
    private static bool IsLocalHost(string host)
    {
        if (host == null)
            return false;
        string value = host.Trim().ToLowerInvariant();
        return value == "127.0.0.1" || value == "localhost" || value == "::1" ||
            value == "[::1]" || value == "0.0.0.0" || value == "::" || value == "[::]";
    }

    private static bool IsExternalMode(LauncherConfig cfg)
    {
        return cfg != null && string.Equals(cfg.ServerMode, "external", StringComparison.OrdinalIgnoreCase);
    }

    /// <summary>True when the URL points at this machine.</summary>
    private static bool UrlHostIsLocal(string url)
    {
        try
        {
            return IsLocalHost(new Uri(url).Host);
        }
        catch
        {
            return false;
        }
    }

    /// <summary>Window URL: externalUrl wins verbatim (one trailing slash is
    /// added); otherwise http://host:port/.</summary>
    private static string BuildAppUrl(LauncherConfig cfg, out bool valid)
    {
        valid = true;
        string external = cfg.ExternalUrl == null ? "" : cfg.ExternalUrl.Trim();
        if (external.Length > 0)
        {
            Uri parsed;
            if (!Uri.TryCreate(external, UriKind.Absolute, out parsed) ||
                (parsed.Scheme != "http" && parsed.Scheme != "https"))
            {
                valid = false;
                configWarnings.Add("invalid externalUrl: " + external);
                return external;
            }
            return external.EndsWith("/", StringComparison.Ordinal) ? external : external + "/";
        }
        return "http://" + cfg.Host + ":" + cfg.Port.ToString(CultureInfo.InvariantCulture) + "/";
    }

    private static LauncherConfig LoadConfig(string path)
    {
        LauncherConfig cfg = new LauncherConfig();
        configWarnings.Clear();
        configInvalid = false;
        if (!File.Exists(path))
        {
            cfg.HostIsLocal = IsLocalHost(cfg.Host);
            return cfg;
        }
        try
        {
            JavaScriptSerializer serializer = new JavaScriptSerializer();
            Dictionary<string, object> map =
                serializer.Deserialize<Dictionary<string, object>>(File.ReadAllText(path, Encoding.UTF8));
            if (map == null)
            {
                cfg.HostIsLocal = IsLocalHost(cfg.Host);
                return cfg;
            }
            if (map.ContainsKey("host") && map["host"] is string) cfg.Host = (string)map["host"];
            if (cfg.Host == null || cfg.Host.Trim().Length == 0)
                cfg.Host = DefaultHost;
            if (map.ContainsKey("port")) cfg.Port = Convert.ToInt32(map["port"]);
            if (map.ContainsKey("waitTimeoutMs")) cfg.WaitTimeoutMs = Convert.ToInt32(map["waitTimeoutMs"]);
            if (map.ContainsKey("killServerOnClose")) cfg.KillServerOnClose = Convert.ToBoolean(map["killServerOnClose"]);
            if (map.ContainsKey("permissionMode") && map["permissionMode"] is string)
                cfg.PermissionMode = (string)map["permissionMode"];
            if (map.ContainsKey("checkUpdates")) cfg.CheckUpdates = Convert.ToBoolean(map["checkUpdates"]);
            if (map.ContainsKey("updateRepo") && map["updateRepo"] is string)
                cfg.UpdateRepo = (string)map["updateRepo"];
            if (map.ContainsKey("closeToTray")) cfg.CloseToTray = Convert.ToBoolean(map["closeToTray"]);
            if (map.ContainsKey("logFile")) cfg.LogFile = Convert.ToBoolean(map["logFile"]);

            if (map.ContainsKey("sessionNotify"))
            {
                try
                {
                    cfg.SessionNotify = Convert.ToBoolean(map["sessionNotify"]);
                }
                catch
                {
                    configWarnings.Add("sessionNotify is not a boolean, using false");
                }
            }
            if (map.ContainsKey("sessionRunningSelector"))
            {
                string selector = map["sessionRunningSelector"] as string;
                if (selector != null && selector.Trim().Length > 0)
                    cfg.SessionRunningSelector = selector.Trim();
                else
                    configWarnings.Add("sessionRunningSelector is empty or not a string, using the default selector");
            }
            if (map.ContainsKey("sessionNotifyIntervalMs"))
            {
                int interval;
                try
                {
                    interval = Convert.ToInt32(map["sessionNotifyIntervalMs"]);
                }
                catch
                {
                    interval = 0;
                }
                if (interval < MinSessionIntervalMs || interval > MaxSessionIntervalMs)
                {
                    configWarnings.Add("sessionNotifyIntervalMs " + interval + " is outside " +
                        MinSessionIntervalMs + "-" + MaxSessionIntervalMs + ", using " + DefaultSessionIntervalMs);
                    interval = DefaultSessionIntervalMs;
                }
                cfg.SessionNotifyIntervalMs = interval;
            }

            if (map.ContainsKey("externalUrl") && map["externalUrl"] is string)
                cfg.ExternalUrl = ((string)map["externalUrl"]).Trim();

            string mode = "";
            if (map.ContainsKey("serverMode"))
            {
                if (map["serverMode"] is string)
                    mode = ((string)map["serverMode"]).Trim().ToLowerInvariant();
                else
                {
                    mode = "?";
                    configWarnings.Add("serverMode is not a string, falling back to local");
                }
            }
            if (mode == "external")
                cfg.ServerMode = "external";
            else if (mode == "local" || mode.Length == 0)
                cfg.ServerMode = "local";
            else
            {
                cfg.ServerMode = "local";
                if (mode != "?")
                    configWarnings.Add("invalid serverMode '" + mode + "', falling back to local");
            }
            // A non-empty externalUrl always means external mode.
            if (cfg.ExternalUrl.Length > 0)
            {
                if (cfg.ServerMode == "local" && mode == "local")
                    configWarnings.Add("serverMode=local ignored because externalUrl is set");
                cfg.ServerMode = "external";
            }
        }
        catch
        {
            // A broken config file falls back to defaults; never block startup.
            configWarnings.Add("invalid config file, using defaults");
            configInvalid = true;
            cfg = new LauncherConfig();
        }
        cfg.HostIsLocal = IsLocalHost(cfg.Host);
        return cfg;
    }

    private static Process StartHarness()
    {
        ProcessStartInfo start = new ProcessStartInfo();
        start.FileName = paths.NodeExe;
        start.Arguments = Quote(paths.DshEntry) + " --profile web --patch " + Quote(patchPath) +
            " --host " + config.Host + " --port " + config.Port.ToString(CultureInfo.InvariantCulture);
        start.WorkingDirectory = Environment.GetFolderPath(Environment.SpecialFolder.MyDocuments);
        start.UseShellExecute = false;
        start.CreateNoWindow = true;
        start.WindowStyle = ProcessWindowStyle.Hidden;
        start.EnvironmentVariables["DSH_PERMISSION_MODE"] = config.PermissionMode;
        start.EnvironmentVariables["DSH_TELEMETRY_MODE"] = "DISABLED";
        string nodeRoot = Path.GetDirectoryName(paths.NodeExe);
        string pathExtra = nodeRoot + ";" + (Directory.Exists(paths.GitCmd) ? paths.GitCmd + ";" : "");
        start.EnvironmentVariables["PATH"] = pathExtra + (Environment.GetEnvironmentVariable("PATH") ?? string.Empty);
        return Process.Start(start);
    }

    private static bool WaitFor(string url, int timeoutMs)
    {
        Stopwatch timer = Stopwatch.StartNew();
        while (timer.ElapsedMilliseconds < timeoutMs)
        {
            if (IsOnline(url, 1000))
                return true;
            Thread.Sleep(300);
        }
        return false;
    }

    internal static bool IsOnline(string url, int timeoutMs)
    {
        try
        {
            HttpWebRequest request = (HttpWebRequest)WebRequest.Create(url);
            request.Method = "GET";
            request.Timeout = timeoutMs;
            request.ReadWriteTimeout = timeoutMs;
            using (HttpWebResponse response = (HttpWebResponse)request.GetResponse())
                return (int)response.StatusCode >= 200 && (int)response.StatusCode < 500;
        }
        catch (WebException error)
        {
            // A 3xx/4xx (login page, auth challenge) still proves the server
            // is up; only transport failures and 5xx count as offline.
            HttpWebResponse failed = error.Response as HttpWebResponse;
            if (failed == null)
                return false;
            int status = (int)failed.StatusCode;
            failed.Close();
            return status < 500;
        }
        catch
        {
            return false;
        }
    }

    private static string Quote(string value)
    {
        return "\"" + value.Replace("\"", "\\\"") + "\"";
    }

    // ---- session state probe ----
    // The chat UI marks the elements it renders while a turn is running with a
    // `_running` CSS-module suffix. The probe polls the DOM from inside the
    // page and reports only transitions, so the launcher never needs the
    // server-side mux protocol. It is injected even when notifications are
    // off: that keeps "probe did not run" distinguishable from "probe ran but
    // stayed silent" in the log.

    internal static string SessionRunningSelector
    {
        get
        {
            string selector = config == null ? null : config.SessionRunningSelector;
            if (selector == null || selector.Trim().Length == 0)
                return DefaultSessionSelector;
            return selector.Trim();
        }
    }

    internal static int SessionNotifyIntervalMs
    {
        get
        {
            int interval = config == null ? DefaultSessionIntervalMs : config.SessionNotifyIntervalMs;
            if (interval < MinSessionIntervalMs || interval > MaxSessionIntervalMs)
                return DefaultSessionIntervalMs;
            return interval;
        }
    }

    internal static bool SessionNotifyEnabled
    {
        get { return config != null && config.SessionNotify; }
    }

    /// <summary>Escapes a value for a single-quoted JavaScript string literal.</summary>
    private static string JsSingleQuoted(string value)
    {
        StringBuilder escaped = new StringBuilder();
        escaped.Append('\'');
        foreach (char c in value)
        {
            switch (c)
            {
                case '\\': escaped.Append("\\\\"); break;
                case '\'': escaped.Append("\\'"); break;
                case '"': escaped.Append("\\\""); break;
                case '\n': escaped.Append("\\n"); break;
                case '\r': escaped.Append("\\r"); break;
                case '\t': escaped.Append("\\t"); break;
                case '\u2028': escaped.Append("\\u2028"); break;
                case '\u2029': escaped.Append("\\u2029"); break;
                // Keeps a stray "</script>" in the selector from ending the block.
                case '<': escaped.Append("\\u003c"); break;
                default: escaped.Append(c); break;
            }
        }
        escaped.Append('\'');
        return escaped.ToString();
    }

    /// <summary>Script registered once via AddScriptToExecuteOnDocumentCreated,
    /// so it also runs after every navigation and reload.</summary>
    internal static string BuildSessionProbeScript()
    {
        string selector = JsSingleQuoted(SessionRunningSelector);
        string interval = SessionNotifyIntervalMs.ToString(CultureInfo.InvariantCulture);
        return
            "(function () {\r\n" +
            "  if (window.__dshSessionProbeInstalled) { return; }\r\n" +
            "  window.__dshSessionProbeInstalled = true;\r\n" +
            "  var SEL = " + selector + ";\r\n" +
            "  var IV = " + interval + ";\r\n" +
            "  var last = null;\r\n" +
            "  function running() {\r\n" +
            "    try { return document.querySelector(SEL) ? true : false; } catch (e) { return null; }\r\n" +
            "  }\r\n" +
            "  function post(message) {\r\n" +
            "    try { window.chrome.webview.postMessage(message); } catch (e) { }\r\n" +
            "  }\r\n" +
            "  setInterval(function () {\r\n" +
            "    var now = running();\r\n" +
            "    if (now === null) { return; }\r\n" +
            "    if (last === null) {\r\n" +
            "      last = now;\r\n" +
            "      post('session-state:' + (now ? '1' : '0'));\r\n" +
            "      return;\r\n" +
            "    }\r\n" +
            "    if (now !== last) {\r\n" +
            "      last = now;\r\n" +
            "      post(now ? 'session-busy' : 'session-idle');\r\n" +
            "    }\r\n" +
            "  }, IV);\r\n" +
            "})();\r\n";
    }

    [DllImport("user32.dll")]
    private static extern bool SetForegroundWindow(IntPtr hWnd);

    [DllImport("user32.dll")]
    private static extern IntPtr GetForegroundWindow();

    [DllImport("user32.dll")]
    private static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);

    [DllImport("user32.dll")]
    private static extern bool EnumWindows(EnumWindowsProc callback, IntPtr lParam);

    [DllImport("user32.dll")]
    private static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint processId);

    private delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);

    /// <summary>True only when this window is visible, not minimized and is the
    /// OS foreground window. ContainsFocus cannot answer that: a form hidden to
    /// the tray still reports focus, which silently killed the idle balloon.
    /// An uncreated handle (0) counts as "not looking", so notifications still
    /// fire instead of throwing.</summary>
    internal static bool IsUserLookingAtWindow(Form form)
    {
        try
        {
            if (form == null || form.IsDisposed || !form.Visible)
                return false;
            if (form.WindowState == FormWindowState.Minimized)
                return false;
            // Reading Handle would create it; only compare an existing one.
            if (!form.IsHandleCreated)
                return false;
            IntPtr foreground = GetForegroundWindow();
            if (foreground == IntPtr.Zero)
                return false;
            return foreground == form.Handle;
        }
        catch
        {
            return false;
        }
    }

    private static void FocusExistingInstance()
    {
        Process current = Process.GetCurrentProcess();
        uint targetPid = 0;
        foreach (Process process in Process.GetProcessesByName(current.ProcessName))
        {
            if (process.Id == current.Id)
                continue;
            targetPid = (uint)process.Id;
            break;
        }
        if (targetPid == 0)
            return;
        // MainWindowHandle is zero for a tray-hidden window, so enumerate
        // top-level windows of the owning PID instead (hidden ones included).
        EnumWindows(delegate(IntPtr hWnd, IntPtr lParam)
        {
            uint pid;
            GetWindowThreadProcessId(hWnd, out pid);
            if (pid == targetPid)
            {
                ShowWindow(hWnd, 9); // SW_RESTORE
                SetForegroundWindow(hWnd);
                return false;
            }
            return true;
        }, IntPtr.Zero);
    }

    // ---- one-click installer (--install / --uninstall) ----

    private const string ExeName = "DeepSeek Harness Window.exe";
    private const string ShortcutName = "DeepSeek Harness Window.lnk";
    private const string UninstallKeyPath = @"Software\Microsoft\Windows\CurrentVersion\Uninstall\DeepSeekHarnessWindow";

    private static readonly string[] ShipFiles = new string[]
    {
        ExeName,
        "Microsoft.Web.WebView2.Core.dll",
        "Microsoft.Web.WebView2.WinForms.dll",
        "WebView2Loader.dll"
    };

    private static string InstallDir
    {
        get
        {
            return Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
                "Programs", "dsh-window");
        }
    }

    private static string ShortcutPath(Environment.SpecialFolder folder)
    {
        return Path.Combine(Environment.GetFolderPath(folder), ShortcutName);
    }

    /// <summary>Copies the app into %LOCALAPPDATA%\Programs\dsh-window and
    /// creates desktop / start-menu shortcuts plus an uninstall registry entry.</summary>
    private static bool RunInstall(string appDir)
    {
        try
        {
            string target = InstallDir;
            Directory.CreateDirectory(target);
            foreach (string file in ShipFiles)
            {
                string source = Path.Combine(appDir, file);
                if (File.Exists(source))
                    File.Copy(source, Path.Combine(target, file), true);
            }
            // Ship the config beside the exe so an external-mode install
            // keeps pointing at the same remote server after installation.
            string configSource = Path.Combine(appDir, ConfigFileName);
            if (File.Exists(configSource))
                File.Copy(configSource, Path.Combine(target, ConfigFileName), true);
            string exePath = Path.Combine(target, ExeName);
            if (!File.Exists(exePath))
                throw new InvalidOperationException("未找到应用文件，请把 4 个程序文件与安装器放在同一目录。");

            Version version = Assembly.GetExecutingAssembly().GetName().Version;
            // Plugin-compatible marker: same tag format as GitHub Releases.
            File.WriteAllText(Path.Combine(target, "installed-version.txt"), "v" + version.ToString(3));

            CreateShortcut(ShortcutPath(Environment.SpecialFolder.DesktopDirectory), exePath, target);
            CreateShortcut(ShortcutPath(Environment.SpecialFolder.Programs), exePath, target);

            using (Microsoft.Win32.RegistryKey key =
                Microsoft.Win32.Registry.CurrentUser.CreateSubKey(UninstallKeyPath))
            {
                key.SetValue("DisplayName", "DeepSeek Harness Window");
                key.SetValue("DisplayVersion", version.ToString(3));
                key.SetValue("Publisher", "Community project (not affiliated with DeepSeek)");
                key.SetValue("InstallLocation", target);
                key.SetValue("DisplayIcon", exePath + ",0");
                key.SetValue("UninstallString", Quote(exePath) + " --uninstall");
                key.SetValue("NoModify", 1);
                key.SetValue("NoRepair", 1);
            }

            WriteInstallLog("installed to " + target + " (v" + version.ToString(3) + ")");
            bool configCopied = File.Exists(Path.Combine(target, ConfigFileName));
            MessageBox.Show(
                "安装完成。\n\n位置：" + target + "\n\n已在桌面和开始菜单创建快捷方式。" +
                (configCopied ? "\n\n配置 dsh-window.config.json 已一并安装。" : ""),
                AppTitle, MessageBoxButtons.OK, MessageBoxIcon.Information);
            return true;
        }
        catch (Exception error)
        {
            MessageBox.Show("安装失败：" + error.Message, AppTitle, MessageBoxButtons.OK, MessageBoxIcon.Error);
            return false;
        }
    }

    /// <summary>Removes shortcuts and the uninstall entry, then deletes the
    /// install directory when nothing else remains in it.</summary>
    private static bool RunUninstall()
    {
        try
        {
            TryDelete(ShortcutPath(Environment.SpecialFolder.DesktopDirectory));
            TryDelete(ShortcutPath(Environment.SpecialFolder.Programs));
            try
            {
                Microsoft.Win32.Registry.CurrentUser.DeleteSubKeyTree(UninstallKeyPath, false);
            }
            catch
            {
            }

            string target = InstallDir;
            bool removedDir = false;
            try
            {
                if (Directory.Exists(target))
                {
                    foreach (string file in ShipFiles)
                        TryDelete(Path.Combine(target, file));
                    TryDelete(Path.Combine(target, "installed-version.txt"));
                    TryDelete(Path.Combine(target, ConfigFileName));
                    if (Directory.GetFileSystemEntries(target).Length == 0)
                    {
                        Directory.Delete(target);
                        removedDir = true;
                    }
                }
            }
            catch
            {
            }

            WriteInstallLog("uninstalled, dir removed=" + removedDir);
            MessageBox.Show(
                "已卸载。快捷方式和注册表项已移除。" +
                "\n配置（dsh-window.config.json）已一并清除。" +
                (removedDir ? "\n安装目录已删除。" : "\n安装目录仍有其它文件，未删除。"),
                AppTitle, MessageBoxButtons.OK, MessageBoxIcon.Information);
            return true;
        }
        catch (Exception error)
        {
            MessageBox.Show("卸载失败：" + error.Message, AppTitle, MessageBoxButtons.OK, MessageBoxIcon.Error);
            return false;
        }
    }

    /// <summary>Creates a .lnk via WScript.Shell COM (reflection, no interop assembly).</summary>
    private static void CreateShortcut(string lnkPath, string targetPath, string workDir)
    {
        Type shellType = Type.GetTypeFromProgID("WScript.Shell");
        object shell = Activator.CreateInstance(shellType);
        object lnk = shellType.InvokeMember("CreateShortcut",
            System.Reflection.BindingFlags.InvokeMethod, null, shell, new object[] { lnkPath });
        Type lnkType = lnk.GetType();
        lnkType.InvokeMember("TargetPath",
            System.Reflection.BindingFlags.SetProperty, null, lnk, new object[] { targetPath });
        lnkType.InvokeMember("WorkingDirectory",
            System.Reflection.BindingFlags.SetProperty, null, lnk, new object[] { workDir });
        lnkType.InvokeMember("IconLocation",
            System.Reflection.BindingFlags.SetProperty, null, lnk, new object[] { targetPath + ",0" });
        lnkType.InvokeMember("Save",
            System.Reflection.BindingFlags.InvokeMethod, null, lnk, null);
    }

    private static void TryDelete(string path)
    {
        try
        {
            if (File.Exists(path))
                File.Delete(path);
        }
        catch
        {
        }
    }

    private static void WriteInstallLog(string message)
    {
        try
        {
            Directory.CreateDirectory(Path.GetDirectoryName(LogPath));
            File.AppendAllText(LogPath,
                DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss") + " [installer] " + message + Environment.NewLine,
                Encoding.UTF8);
        }
        catch
        {
        }
    }
}

internal sealed class MainForm : Form
{
    private readonly WebView2 webView;
    private readonly Process ownedServer;
    private readonly bool killServerOnClose;
    private readonly bool closeToTray;
    private readonly bool externalMode;
    private readonly string webUrl;
    private bool serverReady;
    private bool updateCheckQueued;
    private bool reallyExit;
    private NotifyIcon trayIcon;
    private NotifyIcon sessionNotifyIcon;
    private bool sessionRunning;
    private bool trayBalloonShown;
    private readonly System.Windows.Forms.Timer retryTimer;
    private int retryCount;
    private bool retryProbeRunning;
    private bool errorPageShown;

    public MainForm(Process ownedServer, string webUrl, bool serverReady, bool killServerOnClose,
        bool closeToTray, bool externalMode)
    {
        this.ownedServer = ownedServer;
        this.webUrl = webUrl;
        this.serverReady = serverReady;
        this.killServerOnClose = killServerOnClose;
        this.closeToTray = closeToTray;
        this.externalMode = externalMode;

        Text = ProgramTitle;
        MinimumSize = new Size(800, 560);
        try
        {
            Icon = Icon.ExtractAssociatedIcon(Application.ExecutablePath);
        }
        catch
        {
        }

        webView = new WebView2();
        webView.Dock = DockStyle.Fill;
        Controls.Add(webView);

        if (closeToTray)
            SetupTray();

        retryTimer = new System.Windows.Forms.Timer();
        retryTimer.Tick += OnRetryTimerTick;

        Load += OnLoad;
        FormClosed += OnFormClosed;
        // Waking the machine is a good moment to re-probe a remote server.
        SystemEvents.PowerModeChanged += OnPowerModeChanged;
    }

    private const string ProgramTitle = "DeepSeek Harness";

    private void SetupTray()
    {
        try
        {
            trayIcon = new NotifyIcon();
            trayIcon.Icon = Icon.ExtractAssociatedIcon(Application.ExecutablePath);
            trayIcon.Text = ProgramTitle;
            ContextMenuStrip menu = new ContextMenuStrip();
            menu.Items.Add("显示主窗口", null, delegate { ShowFromTray(); });
            menu.Items.Add(new ToolStripSeparator());
            menu.Items.Add("退出", null, delegate
            {
                reallyExit = true;
                Close();
            });
            trayIcon.ContextMenuStrip = menu;
            trayIcon.DoubleClick += delegate { ShowFromTray(); };
            // Also restores the window from the session-idle balloon, which
            // reuses this icon whenever closeToTray is on.
            trayIcon.BalloonTipClicked += delegate { ShowFromTray(); };
            trayIcon.Visible = true;
            Program.Log("tray icon created");
        }
        catch (Exception error)
        {
            Program.Log("tray setup failed: " + error.Message);
            // A half-built icon must not shadow the one the session
            // notification creates on demand.
            if (trayIcon != null)
            {
                try
                {
                    trayIcon.Visible = false;
                    trayIcon.Dispose();
                }
                catch
                {
                }
                trayIcon = null;
            }
        }
    }

    private void ShowFromTray()
    {
        Show();
        if (WindowState == FormWindowState.Minimized)
            WindowState = FormWindowState.Normal;
        Activate();
    }

    protected override void WndProc(ref Message m)
    {
        const int WM_CLOSE = 0x0010;
        // WebView2 intercepts WM_CLOSE and re-raises FormClosing with a
        // non-UserClosing reason, so handle the X button here directly.
        if (m.Msg == WM_CLOSE && closeToTray && !reallyExit)
        {
            HideToTray();
            return;
        }
        base.WndProc(ref m);
    }

    private void HideToTray()
    {
        Hide();
        Program.Log("canceled close, hidden to tray");
        if (!trayBalloonShown && trayIcon != null)
        {
            trayBalloonShown = true;
            try
            {
                trayIcon.ShowBalloonTip(2000, ProgramTitle, "已最小化到托盘，双击托盘图标可重新打开。", ToolTipIcon.Info);
            }
            catch
            {
            }
        }
    }

    protected override void OnFormClosing(FormClosingEventArgs e)
    {
        Program.Log("form closing: reason=" + e.CloseReason + ", closeToTray=" + closeToTray + ", reallyExit=" + reallyExit);
        if (closeToTray && !reallyExit && e.CloseReason != CloseReason.WindowsShutDown)
        {
            e.Cancel = true;
            HideToTray();
            return;
        }
        base.OnFormClosing(e);
    }

    private async void OnLoad(object sender, EventArgs e)
    {
        try
        {
            string userData = Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
                "DeepSeekHarnessWindow", "WebView2Data");
            CoreWebView2Environment environment =
                await CoreWebView2Environment.CreateAsync(null, userData);
            await webView.EnsureCoreWebView2Async(environment);

            webView.CoreWebView2.Settings.IsStatusBarEnabled = false;
            webView.CoreWebView2.Settings.AreDefaultContextMenusEnabled = true;
            webView.CoreWebView2.NewWindowRequested += OnNewWindowRequested;
            // WebView2 silently drops a top-level navigation to an unregistered
            // scheme (e.g. the "dshvnc:" link the desktop-ctl sidebar button
            // clicks). Catch it here and hand it to the OS instead.
            webView.CoreWebView2.NavigationStarting += OnNavigationStarting;
            webView.CoreWebView2.WebMessageReceived += OnWebMessageReceived;
            webView.CoreWebView2.NavigationCompleted += OnNavigationCompleted;
            webView.CoreWebView2.DocumentTitleChanged += delegate
            {
                string title = webView.CoreWebView2.DocumentTitle;
                if (!string.IsNullOrEmpty(title))
                    Text = title;
            };

            // Registered once, on the document-created hook, so every
            // navigation and reload picks the probe up without re-injecting.
            try
            {
                await webView.CoreWebView2.AddScriptToExecuteOnDocumentCreatedAsync(
                    Program.BuildSessionProbeScript());
                Program.Log("session probe injected, selector=" + Program.SessionRunningSelector +
                    ", intervalMs=" + Program.SessionNotifyIntervalMs.ToString(CultureInfo.InvariantCulture) +
                    ", sessionNotify=" + Program.SessionNotifyEnabled);
            }
            catch (Exception probeError)
            {
                Program.Log("session probe injection failed: " + probeError.Message);
            }

            RestoreWindowState();

            if (serverReady)
            {
                errorPageShown = false;
                webView.CoreWebView2.Navigate(webUrl);
            }
            else
            {
                ShowErrorPageAndScheduleRetry();
            }
        }
        catch (Exception error)
        {
            MessageBox.Show(
                "无法初始化窗口组件（WebView2）。\n\n请安装 Microsoft Edge WebView2 Runtime 后重试：\nhttps://developer.microsoft.com/microsoft-edge/webview2/\n\n错误：" + error.Message,
                ProgramTitle,
                MessageBoxButtons.OK,
                MessageBoxIcon.Error);
            Close();
        }
    }

    private void OnNavigationCompleted(object sender, CoreWebView2NavigationCompletedEventArgs e)
    {
        if (!e.IsSuccess)
        {
            // Navigation itself failed (remote went away mid-flight).
            serverReady = false;
            Program.Log("navigation failed: " + e.WebErrorStatus);
            if (!errorPageShown)
                ShowErrorPageAndScheduleRetry();
            return;
        }
        // NavigateToString also completes "successfully"; never treat our own
        // error page as a restored connection.
        if (errorPageShown)
            return;
        // A successful navigation means the connection is back: reset backoff.
        retryCount = 0;
        retryTimer.Stop();
        serverReady = true;
        if (updateCheckQueued)
            return;
        updateCheckQueued = true;
        Program.Log("navigation completed, queueing update check");
        ThreadPool.QueueUserWorkItem(delegate
        {
            Program.UpdateInfo info = Program.CheckForUpdates();
            if (info != null)
            {
                Program.Log("update available: " + info.LatestVersion);
                try
                {
                    BeginInvoke((Action)delegate { ShowUpdateBanner(info); });
                }
                catch
                {
                }
            }
            else
            {
                Program.Log("update check: up to date");
            }
        });
    }

    private void ShowUpdateBanner(Program.UpdateInfo info)
    {
        try
        {
            string version = (info.LatestVersion ?? "").Replace("'", "").Replace("\"", "");
            string url = (info.ReleaseUrl ?? "").Replace("'", "").Replace("\"", "");
            string js =
                "(function(){" +
                "if(document.getElementById('dshw-update-banner'))return;" +
                "var b=document.createElement('div');b.id='dshw-update-banner';" +
                "b.style.cssText='position:fixed;bottom:16px;right:16px;z-index:99999;background:#2f6fed;color:#fff;" +
                "padding:10px 16px;border-radius:8px;font:13px system-ui;box-shadow:0 2px 10px rgba(0,0,0,.25);" +
                "display:flex;gap:12px;align-items:center';" +
                "b.innerHTML=\"<span>有新版本 " + version + "</span>" +
                "<a href='" + url + "' target='_blank' style='color:#fff;font-weight:600'>查看</a>" +
                "<a href='#' onclick=\\\"this.parentNode.remove();return false\\\" style='color:rgba(255,255,255,.75)'>✕</a>\";" +
                "document.body.appendChild(b);" +
                "})();";
            webView.CoreWebView2.ExecuteScriptAsync(js);
        }
        catch (Exception error)
        {
            Program.Log("update banner failed: " + error.Message);
        }
    }

    private string BuildErrorPage()
    {
        string heading = externalMode ? "连不上远程 DeepSeek Harness 服务" : "DeepSeek Harness 服务没有响应";
        string safeUrl = webUrl.Replace("\"", "%22");
        string body = externalMode
            ? "目标地址：" + safeUrl + "。请确认远程机器上的 DSH 已启动、网络可达。"
            : "启动本地服务后没有在预期时间内连上。点下面的按钮再试一次。";
        string retryLine = "";
        if (retryCount > 0)
        {
            retryLine = "<p id=\"dshw-retry\">自动重试：第 " + retryCount.ToString(CultureInfo.InvariantCulture) +
                " 次，" + NextRetrySeconds(retryCount).ToString(CultureInfo.InvariantCulture) + " 秒后</p>";
        }
        return
            "<html><head><meta charset=\"utf-8\"><title>连接失败 - " + ProgramTitle + "</title>" +
            "<style>body{font-family:'Segoe UI',system-ui,sans-serif;background:#f5f6f8;display:flex;" +
            "align-items:center;justify-content:center;height:100vh;margin:0;color:#1f2328}" +
            ".card{background:#fff;padding:40px 48px;border-radius:12px;box-shadow:0 2px 12px rgba(0,0,0,.08);" +
            "max-width:480px;text-align:center}h1{font-size:20px;margin:0 0 12px}" +
            "p{color:#59636e;font-size:14px;line-height:1.6;margin:0 0 24px}" +
            "#dshw-retry{font-size:13px;color:#8a6d3b;margin:-12px 0 24px}" +
            "button{background:#2f6fed;color:#fff;border:none;border-radius:8px;padding:10px 28px;" +
            "font-size:14px;cursor:pointer}button:hover{background:#2557c0}" +
            "a{display:block;margin-top:16px;color:#59636e;font-size:13px}</style></head><body>" +
            "<div class=\"card\"><h1>" + heading + "</h1>" +
            "<p>" + body + "</p>" +
            retryLine +
            "<button onclick=\"window.chrome.webview.postMessage('retry')\">重试</button>" +
            "<a href=\"" + safeUrl + "\" target=\"_blank\">在浏览器中打开</a></div></body></html>";
    }

    /// <summary>Backoff schedule for automatic reconnects: 2, 5, 10, then 30s.</summary>
    private static int NextRetrySeconds(int attempt)
    {
        if (attempt <= 1)
            return 2;
        if (attempt == 2)
            return 5;
        if (attempt == 3)
            return 10;
        return 30;
    }

    private void ShowErrorPageAndScheduleRetry()
    {
        if (webView.CoreWebView2 == null)
            return;
        retryCount++;
        int seconds = NextRetrySeconds(retryCount);
        Program.Log("retry #" + retryCount.ToString(CultureInfo.InvariantCulture) +
            " in " + seconds.ToString(CultureInfo.InvariantCulture) + "s");
        errorPageShown = true;
        webView.CoreWebView2.NavigateToString(BuildErrorPage());
        retryTimer.Stop();
        retryTimer.Interval = seconds * 1000;
        retryTimer.Start();
    }

    private void OnRetryTimerTick(object sender, EventArgs e)
    {
        retryTimer.Stop();
        TryReconnect(true);
    }

    /// <summary>Probes the URL once; navigates when reachable, otherwise
    /// re-renders the error page with the next backoff step.</summary>
    private void TryReconnect(bool reschedule)
    {
        if (retryProbeRunning)
            return;
        retryProbeRunning = true;
        // Probe off the UI thread: a dead host can take seconds to time out.
        ThreadPool.QueueUserWorkItem(delegate
        {
            // External mode only probes; local mode may still need to
            // (re)start the service it owns.
            bool online = externalMode
                ? Program.IsOnline(webUrl, 2500)
                : Program.EnsureServer();
            try
            {
                BeginInvoke((Action)delegate
                {
                    retryProbeRunning = false;
                    ApplyProbeResult(online, reschedule);
                });
            }
            catch
            {
                retryProbeRunning = false;
            }
        });
    }

    private void ApplyProbeResult(bool online, bool reschedule)
    {
        if (online)
        {
            // Do not reset the counter here: only a navigation that actually
            // succeeded proves the connection is back.
            serverReady = true;
            errorPageShown = false;
            if (webView.CoreWebView2 != null)
                webView.CoreWebView2.Navigate(webUrl);
            return;
        }
        serverReady = false;
        if (reschedule)
            ShowErrorPageAndScheduleRetry();
    }

    private void OnWebMessageReceived(object sender, CoreWebView2WebMessageReceivedEventArgs e)
    {
        try
        {
            string message = e.TryGetWebMessageAsString();
            if (message == null)
                return;
            if (message == "retry")
            {
                // Manual retry: reset the backoff, probe once, never spawn in
                // external mode.
                retryTimer.Stop();
                retryCount = 0;
                TryReconnect(true);
                return;
            }
            // Prefix matching on purpose: no JSON parsing for four fixed
            // tokens, and unknown messages keep being ignored.
            if (message.StartsWith("session-busy", StringComparison.Ordinal) ||
                message.StartsWith("session-state:1", StringComparison.Ordinal))
            {
                OnSessionRunning();
                return;
            }
            if (message.StartsWith("session-idle", StringComparison.Ordinal))
            {
                OnSessionIdle(true);
                return;
            }
            if (message.StartsWith("session-state:0", StringComparison.Ordinal))
            {
                // First sample of a fresh document: not a transition, so it
                // never raises a notification.
                OnSessionIdle(false);
            }
        }
        catch
        {
        }
    }

    private void OnSessionRunning()
    {
        sessionRunning = true;
        Program.Log("session state: running=true");
    }

    /// <summary>A session just stopped running. Only a real running -> idle
    /// transition with notifications enabled and the window not in front of
    /// the user raises a balloon.</summary>
    private void OnSessionIdle(bool transition)
    {
        bool wasRunning = sessionRunning;
        sessionRunning = false;
        // ContainsFocus lies for a window hidden to the tray (it keeps
        // reporting true), so ask Win32 for the real foreground window and
        // also require visibility and a non-minimized state.
        bool notify = transition && wasRunning && Program.SessionNotifyEnabled &&
            !Program.IsUserLookingAtWindow(this);
        if (notify)
            ShowSessionIdleNotification();
        Program.Log("session state: running=false, notify=" + (notify ? "yes" : "no"));
    }

    private void ShowSessionIdleNotification()
    {
        try
        {
            NotifyIcon icon = EnsureSessionNotifyIcon();
            if (icon == null)
            {
                Program.Log("session notification skipped: no tray icon available");
                return;
            }
            icon.ShowBalloonTip(5000, ProgramTitle, "会话已空闲，等待你的输入。点击回到窗口。", ToolTipIcon.Info);
            Program.Log("session notification shown");
        }
        catch (Exception error)
        {
            Program.Log("session notification failed: " + error.Message);
        }
    }

    /// <summary>Reuses the closeToTray icon when present, otherwise creates a
    /// dedicated one for the lifetime of the form.</summary>
    private NotifyIcon EnsureSessionNotifyIcon()
    {
        if (trayIcon != null)
            return trayIcon;
        if (sessionNotifyIcon != null)
            return sessionNotifyIcon;
        NotifyIcon created = new NotifyIcon();
        created.Icon = Icon.ExtractAssociatedIcon(Application.ExecutablePath);
        created.Text = ProgramTitle;
        created.BalloonTipClicked += delegate { ShowFromTray(); };
        created.Visible = true;
        sessionNotifyIcon = created;
        Program.Log("session notification tray icon created");
        return sessionNotifyIcon;
    }

    private void DisposeSessionNotifyIcon()
    {
        if (sessionNotifyIcon == null)
            return;
        try
        {
            sessionNotifyIcon.Visible = false;
            sessionNotifyIcon.Dispose();
        }
        catch
        {
        }
        sessionNotifyIcon = null;
    }

    private void OnPowerModeChanged(object sender, PowerModeChangedEventArgs e)
    {
        if (e.Mode != PowerModes.Resume)
            return;
        Program.Log("power resume, immediate retry");
        // SystemEvents raises this on its own thread; marshal to the UI thread.
        try
        {
            BeginInvoke((Action)delegate
            {
                retryTimer.Stop();
                retryCount = 0;
                TryReconnect(true);
            });
        }
        catch
        {
        }
    }

    private void OnNewWindowRequested(object sender, CoreWebView2NewWindowRequestedEventArgs e)
    {
        // Every popup goes to the system browser, deliberately: the embedded
        // window is a single-page shell and has no chrome for extra tabs.
        // So the IsExternalScheme filter is intentionally not applied here and
        // http/https popups keep opening in the system browser as before.
        e.Handled = true;
        try
        {
            Process.Start(new ProcessStartInfo(e.Uri) { UseShellExecute = true });
        }
        catch
        {
        }
    }

    private void OnNavigationStarting(object sender, CoreWebView2NavigationStartingEventArgs e)
    {
        string uri = e.Uri;
        if (!IsExternalScheme(uri))
        {
            return;
        }
        // Cancel first: WebView2 would otherwise fail the navigation itself and
        // leave the shell showing the previous page with no feedback at all.
        e.Cancel = true;
        Program.Log("navigation to external scheme handed to OS: " + uri);
        try
        {
            Process.Start(new ProcessStartInfo(uri) { UseShellExecute = true });
        }
        catch
        {
        }
    }

    /// <summary>
    /// True when a URI should be handed to the operating system instead of being
    /// rendered inside the embedded browser.
    /// </summary>
    private static bool IsExternalScheme(string uri)
    {
        if (string.IsNullOrEmpty(uri))
            return true;
        Uri parsed;
        if (!Uri.TryCreate(uri, UriKind.Absolute, out parsed))
            return true;
        switch (parsed.Scheme.ToLowerInvariant())
        {
            case "http":
            case "https":
            case "file":
            case "about":
            case "data":
            case "blob":
            case "chrome":
            case "edge":
            case "ws":
            case "wss":
                return false;
            default:
                return true;
        }
    }

    private string StatePath
    {
        get
        {
            return Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
                "DeepSeekHarnessWindow", "window-state.json");
        }
    }

    private void RestoreWindowState()
    {
        try
        {
            if (!File.Exists(StatePath))
            {
                ApplyFirstRunBounds();
                return;
            }
            JavaScriptSerializer serializer = new JavaScriptSerializer();
            Dictionary<string, object> state =
                serializer.Deserialize<Dictionary<string, object>>(File.ReadAllText(StatePath, Encoding.UTF8));
            if (state == null)
            {
                ApplyFirstRunBounds();
                return;
            }

            int x = state.ContainsKey("x") ? Convert.ToInt32(state["x"]) : int.MinValue;
            int y = state.ContainsKey("y") ? Convert.ToInt32(state["y"]) : int.MinValue;
            int w = state.ContainsKey("w") ? Convert.ToInt32(state["w"]) : 0;
            int h = state.ContainsKey("h") ? Convert.ToInt32(state["h"]) : 0;
            bool maximized = state.ContainsKey("maximized") && Convert.ToBoolean(state["maximized"]);

            // Migration: v1.x saved 96-DPI virtualized pixels (process was
            // DPI-unaware); since 1.2.1 the process is per-monitor aware and
            // works in physical pixels. Scale old values by the system DPI
            // ratio once, then persist ver=2 on the next save.
            bool legacy = !state.ContainsKey("ver") || Convert.ToInt32(state["ver"]) < 2;
            if (legacy)
            {
                float scale = GetSystemDpiScale();
                if (scale > 1f)
                {
                    x = (int)Math.Round(x * scale);
                    y = (int)Math.Round(y * scale);
                    w = (int)Math.Round(w * scale);
                    h = (int)Math.Round(h * scale);
                }
            }

            bool onScreen = false;
            if (w >= MinimumSize.Width && h >= MinimumSize.Height)
            {
                Rectangle bounds = new Rectangle(x, y, w, h);
                foreach (Screen screen in Screen.AllScreens)
                {
                    if (screen.WorkingArea.IntersectsWith(bounds))
                    {
                        onScreen = true;
                        break;
                    }
                }
            }
            if (onScreen)
            {
                StartPosition = FormStartPosition.Manual;
                Bounds = new Rectangle(x, y, w, h);
            }
            else
            {
                ApplyFirstRunBounds();
            }
            if (maximized)
                WindowState = FormWindowState.Maximized;
        }
        catch
        {
            ApplyFirstRunBounds();
        }
    }

    /// <summary>First run (or unusable state): 80% of the primary working area,
    /// centered, never below MinimumSize and never larger than the area.</summary>
    private void ApplyFirstRunBounds()
    {
        Screen primary = Screen.PrimaryScreen;
        Rectangle area = primary != null ? primary.WorkingArea : Screen.FromPoint(Cursor.Position).WorkingArea;
        int w = (int)Math.Round(area.Width * 0.8);
        int h = (int)Math.Round(area.Height * 0.8);
        if (w < MinimumSize.Width)
            w = MinimumSize.Width;
        if (h < MinimumSize.Height)
            h = MinimumSize.Height;
        if (w > area.Width)
            w = area.Width;
        if (h > area.Height)
            h = area.Height;
        int x = area.X + (area.Width - w) / 2;
        int y = area.Y + (area.Height - h) / 2;
        StartPosition = FormStartPosition.Manual;
        Bounds = new Rectangle(x, y, w, h);
        Program.Log("window bounds: x=" + x.ToString(CultureInfo.InvariantCulture) +
            " y=" + y.ToString(CultureInfo.InvariantCulture) +
            " w=" + w.ToString(CultureInfo.InvariantCulture) +
            " h=" + h.ToString(CultureInfo.InvariantCulture));
    }

    /// <summary>System DPI ratio (primary monitor DPI / 96) for one-time
    /// migration of pre-1.2.1 window state.</summary>
    private static float GetSystemDpiScale()
    {
        try
        {
            using (Graphics graphics = Graphics.FromHwnd(IntPtr.Zero))
            {
                if (graphics.DpiX > 0)
                    return graphics.DpiX / 96f;
            }
        }
        catch
        {
        }
        return 1f;
    }

    private void SaveWindowState()
    {
        try
        {
            Directory.CreateDirectory(Path.GetDirectoryName(StatePath));
            Rectangle bounds = WindowState == FormWindowState.Normal ? Bounds : RestoreBounds;
            Dictionary<string, object> state = new Dictionary<string, object>();
            state["x"] = bounds.X;
            state["y"] = bounds.Y;
            state["w"] = bounds.Width;
            state["h"] = bounds.Height;
            state["maximized"] = WindowState == FormWindowState.Maximized;
            state["ver"] = 2;
            JavaScriptSerializer serializer = new JavaScriptSerializer();
            File.WriteAllText(StatePath, serializer.Serialize(state), Encoding.UTF8);
        }
        catch
        {
        }
    }

    private void OnFormClosed(object sender, FormClosedEventArgs e)
    {
        Program.Log("form closed, disposing tray and owned server");
        try
        {
            SystemEvents.PowerModeChanged -= OnPowerModeChanged;
        }
        catch
        {
        }
        try
        {
            retryTimer.Stop();
            retryTimer.Dispose();
        }
        catch
        {
        }
        SaveWindowState();
        DisposeSessionNotifyIcon();
        if (trayIcon != null)
        {
            try
            {
                trayIcon.Visible = false;
                trayIcon.Dispose();
            }
            catch
            {
            }
        }
        if (killServerOnClose && ownedServer != null)
        {
            try
            {
                ownedServer.Kill();
                ownedServer.Dispose();
            }
            catch
            {
            }
        }
    }
}
