using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Text;
using System.Text.Json;
using System.Threading.Tasks;

namespace SqlBackupTools.Helpers
{
    // Loads an age-encrypted secrets file via `sops -d --output-type json <path>`
    // and exposes the decrypted keys as a flat dictionary. Source file is
    // expected to hold a flat object of scalar string values.
    //
    // Precondition: `sops.exe` on PATH and a decryptable age key configured
    // (typically via the SOPS_AGE_KEY_FILE env var). See ops/GETTING-STARTED.md.
    public static class SecretsFile
    {
        public static async Task<IReadOnlyDictionary<string, string>> LoadAsync(string path)
        {
            if (string.IsNullOrWhiteSpace(path))
                return new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
            if (!File.Exists(path))
                throw new FileNotFoundException($"Secrets file not found: {path}", path);

            var psi = new ProcessStartInfo
            {
                FileName = "sops",
                RedirectStandardOutput = true,
                RedirectStandardError = true,
                UseShellExecute = false,
                CreateNoWindow = true,
            };
            psi.ArgumentList.Add("-d");
            psi.ArgumentList.Add("--output-type");
            psi.ArgumentList.Add("json");
            psi.ArgumentList.Add(path);

            using var proc = Process.Start(psi)
                ?? throw new InvalidOperationException("Failed to start sops; check that sops.exe is on PATH.");

            var stdoutTask = proc.StandardOutput.ReadToEndAsync();
            var stderrTask = proc.StandardError.ReadToEndAsync();
            await proc.WaitForExitAsync();
            var stdout = await stdoutTask;
            var stderr = await stderrTask;

            if (proc.ExitCode != 0)
                throw new InvalidOperationException($"sops -d failed (exit {proc.ExitCode}): {stderr.Trim()}");

            try
            {
                using var doc = JsonDocument.Parse(stdout);
                var result = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
                foreach (var prop in doc.RootElement.EnumerateObject())
                {
                    if (prop.Value.ValueKind == JsonValueKind.String)
                        result[prop.Name] = prop.Value.GetString();
                }
                return result;
            }
            catch (JsonException ex)
            {
                throw new InvalidOperationException("Decrypted secrets file is not valid JSON. " + ex.Message, ex);
            }
        }
    }
}
