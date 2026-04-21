using System;
using System.Globalization;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
using Serilog;
using SqlBackupTools.Helpers;
using SqlBackupTools.Restore;

namespace SqlBackupTools.Notification
{
    public static class NotificationExtensions
    {
        private static CultureInfo _c = CultureInfo.InvariantCulture;

        public static async Task SendMailgunAsync(this ReportState state, GeneralCommandInfos cfg, ILogger logger, CancellationToken cancellationToken)
        {
            if (string.IsNullOrWhiteSpace(cfg.Email)
                || string.IsNullOrWhiteSpace(cfg.MailgunApiKey)
                || string.IsNullOrWhiteSpace(cfg.MailgunDomain))
            {
                return;
            }

            var subject = $"Restore Backup {Environment.MachineName} : {state.Restored.Count}/{state.TotalProcessed}";

            var sb = new StringBuilder();
            sb.AppendLine(_c, $"Restore finished in {state.TotalTime.HumanizedTimeSpan()}");
            sb.AppendLine();

            if (state.Errors.Count != 0)
            {
                sb.AppendLine(_c, $"Errors : {state.Errors.Count}");
                foreach (var e in state.Errors)
                {
                    sb.AppendLine(_c, $"{e.Item.Name} : {e.Error}");
                }
                sb.AppendLine();
            }

            if (state.BackupNotFoundDbExists.Count != 0)
            {
                sb.AppendLine(_c, $"Warnings : {state.BackupNotFoundDbExists.Count}");
                foreach (var w in state.BackupNotFoundDbExists)
                {
                    sb.AppendLine(_c, $"Db {w.Name} in state {w.State}, no .bak found");
                }
                sb.AppendLine();
            }

            if (state.MissingFull.Count != 0)
            {
                sb.AppendLine(_c, $"Missing .bak : {state.MissingFull.Count}");
                foreach (var w in state.MissingFull)
                {
                    sb.AppendLine("Missing .bak in folder " + w.Path);
                }
                sb.AppendLine();
            }

            if (state.Restored.Count != 0)
            {
                sb.AppendLine(_c, $"OK : {state.Restored.Count}");
                foreach (var o in state.Restored)
                {
                    sb.AppendLine(_c, $"{o.Name}");
                }
                sb.AppendLine();
            }

            var from = string.IsNullOrWhiteSpace(cfg.MailgunFrom)
                ? $"SQL backup <sqlbackup@{cfg.MailgunDomain}>"
                : cfg.MailgunFrom;

            var client = new MailgunClient(logger, cfg.MailgunBaseUrl, cfg.MailgunApiKey, cfg.MailgunDomain);
            await client.SendAsync(from, cfg.Email, subject, sb.ToString(), cancellationToken);
        }
    }
}
