using System;
using System.Diagnostics;
using System.IO;
using System.Security.Principal;

internal static class AudioBluetoothWifiRepairLauncher
{
    private static int Main(string[] args)
    {
        string exePath = Process.GetCurrentProcess().MainModule.FileName;
        string exeDir = Path.GetDirectoryName(exePath);
        DirectoryInfo parent = Directory.GetParent(exeDir);
        string root = parent != null ? parent.FullName : exeDir;
        string script = Path.Combine(root, "scripts", "Repair-AudioBluetoothWifi.ps1");

        if (!File.Exists(script))
        {
            Console.Error.WriteLine("Repair script not found:");
            Console.Error.WriteLine(script);
            Console.Error.WriteLine("Keep the executable inside the project bin folder.");
            return 3;
        }

        string powershell = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.Windows), "System32", "WindowsPowerShell", "v1.0", "powershell.exe");
        string forwarded = BuildPowerShellArguments(script, args);

        try
        {
            var startInfo = new ProcessStartInfo
            {
                FileName = powershell,
                Arguments = forwarded,
                UseShellExecute = true,
                WorkingDirectory = root
            };

            if (!IsAdministrator())
            {
                startInfo.Verb = "runas";
            }

            using (Process process = Process.Start(startInfo))
            {
                if (process == null)
                {
                    Console.Error.WriteLine("Failed to start repair process.");
                    return 4;
                }

                if (IsAdministrator())
                {
                    process.WaitForExit();
                    return process.ExitCode;
                }
            }

            return 0;
        }
        catch (Exception ex)
        {
            Console.Error.WriteLine("Failed to launch repair:");
            Console.Error.WriteLine(ex.Message);
            return 5;
        }
    }

    private static string BuildPowerShellArguments(string script, string[] args)
    {
        string result = "-NoProfile -ExecutionPolicy Bypass -File " + Quote(script);
        foreach (string arg in args)
        {
            result += " " + Quote(arg);
        }
        return result;
    }

    private static string Quote(string value)
    {
        return "\"" + value.Replace("\"", "\\\"") + "\"";
    }

    private static bool IsAdministrator()
    {
        using (WindowsIdentity identity = WindowsIdentity.GetCurrent())
        {
            WindowsPrincipal principal = new WindowsPrincipal(identity);
            return principal.IsInRole(WindowsBuiltInRole.Administrator);
        }
    }
}
