using System;
using System.Collections.Generic;
using System.IO;
using System.Threading.Tasks;
using CommandLine;
using Microsoft.Data.SqlClient;
using SqlBackupTools.Helpers;

namespace SqlBackupTools
{
    public abstract class GeneralCommandInfos
    {
        protected GeneralCommandInfos()
        {
            Threads = Environment.ProcessorCount;
        }

        [Option('h', "hostname", Required = true, HelpText = "SQL Server hostname")]
        public string Hostname { get; set; }

        [Option('l', "login", HelpText = "SQL Server login")]
        public string Login { get; set; }

        [Option('p', "password", HelpText = "SQL Server password. Prefer --secrets-file.")]
        public string Password { get; set; }

        [Option('v', "verbose", HelpText = "Log details")]
        public bool Verbose { get; set; }

        [Option("timeout", HelpText = "SQL Command timeout in seconds")]
        public int Timeout { get; set; } = 90 * 60; // 1h

        [Option("no-encrypt", HelpText = "Disable TLS encryption for the SQL connection. Default: encryption on with TrustServerCertificate=true (encrypted on wire, cert not verified). Only use on a trusted LAN.")]
        public bool NoEncrypt { get; set; }

        [Option("logs", HelpText = "Log folder")]
        public DirectoryInfo LogsPath { get; set; }

        [Option('t', "threads", HelpText = "Parallel threads")]
        public int Threads { get; set; }

        [Option("secrets-file", HelpText = "Path to a SOPS-encrypted secrets file (YAML or JSON). Decrypted via `sops -d --output-type json` at startup. Keys: password, slack_secret, mailgun_api_key, mailgun_domain, mailgun_from, mailgun_base_url. CLI flags win when both are supplied.")]
        public string SecretsFilePath { get; set; }

        [Option("email", HelpText = "Recipient email address for the run report")]
        public string Email { get; set; }

        [Option("mailgun-api-key", HelpText = "Mailgun API key. Prefer --secrets-file.")]
        public string MailgunApiKey { get; set; }

        [Option("mailgun-domain", HelpText = "Mailgun sender domain, e.g. mg.amphora.ee")]
        public string MailgunDomain { get; set; }

        [Option("mailgun-from", HelpText = "RFC 5322 From header, e.g. \"SQL backup <sqlbackup@mg.amphora.ee>\". Defaults to sqlbackup@<mailgun-domain>.")]
        public string MailgunFrom { get; set; }

        [Option("mailgun-base-url", HelpText = "Mailgun REST base URL. Defaults to https://api.eu.mailgun.net/v3.")]
        public string MailgunBaseUrl { get; set; }

        [Option("slackSecret", HelpText = "Slack token. Prefer --secrets-file.")]
        public string SlackSecret { get; internal set; }

        [Option("slackChannel", HelpText = "Slack channel")]
        public string SlackChannel { get; internal set; }

        [Option("slackOnlyOnError", HelpText = "Send slack message only on warning or error")]
        public bool SlackOnlyOnError { get; set; }

        [Option("slackTitle", HelpText = "Slack message title")]
        public string SlackTitle { get; internal set; }

        public virtual void Validate()
        {

        }

        // Overlay secrets from the SOPS-encrypted file onto empty CLI fields.
        // CLI-provided values win over secrets-file values.
        public async Task ApplySecretsFileAsync()
        {
            if (string.IsNullOrWhiteSpace(SecretsFilePath))
                return;

            var secrets = await SecretsFile.LoadAsync(SecretsFilePath);

            if (string.IsNullOrWhiteSpace(Password) && secrets.TryGetValue("password", out var pw))
                Password = pw;
            if (string.IsNullOrWhiteSpace(SlackSecret) && secrets.TryGetValue("slack_secret", out var ss))
                SlackSecret = ss;
            if (string.IsNullOrWhiteSpace(MailgunApiKey) && secrets.TryGetValue("mailgun_api_key", out var mk))
                MailgunApiKey = mk;
            if (string.IsNullOrWhiteSpace(MailgunDomain) && secrets.TryGetValue("mailgun_domain", out var md))
                MailgunDomain = md;
            if (string.IsNullOrWhiteSpace(MailgunFrom) && secrets.TryGetValue("mailgun_from", out var mf))
                MailgunFrom = mf;
            if (string.IsNullOrWhiteSpace(MailgunBaseUrl) && secrets.TryGetValue("mailgun_base_url", out var mb))
                MailgunBaseUrl = mb;
        }

        public SqlConnection CreateConnectionMars(string database = "master")
        {
            var builder = Hostname.PrepareSqlConnectionStringBuilder(database, Login, Password, Timeout, encrypt: !NoEncrypt);
            var connection = new SqlConnection(builder.ConnectionString);
            connection.Open();
            return connection;
        }
    }

    [Verb("drop", HelpText = "Drop all databases")]
    public class DropDatabaseCommand : GeneralCommandInfos
    {
        [Option("ignoreDatabases", HelpText = "Exclude specific databases from drop command")]
        public IEnumerable<string> DuplicatesIgnored { get; set; }


        [Option("force", HelpText = "Avoid confirmation before database drop")]
        public bool Force { get; set; }
    }
}
