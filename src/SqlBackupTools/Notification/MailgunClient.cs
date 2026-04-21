using System;
using System.Collections.Generic;
using System.Net.Http;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
using Serilog;

namespace SqlBackupTools.Notification
{
    // Minimal Mailgun v3 messages client. Matches the flat-form-encoded shape
    // the Mailgun REST API expects; no DNS / domain-management calls.
    public class MailgunClient
    {
        private readonly ILogger _logger;
        private readonly string _baseUrl;
        private readonly string _apiKey;
        private readonly string _domain;

        public MailgunClient(ILogger logger, string baseUrl, string apiKey, string domain)
        {
            _logger = logger;
            _baseUrl = (baseUrl ?? "https://api.eu.mailgun.net/v3").TrimEnd('/');
            _apiKey = apiKey;
            _domain = domain;
        }

        public async Task SendAsync(string from, string to, string subject, string text, CancellationToken ct)
        {
            if (string.IsNullOrWhiteSpace(_apiKey) || string.IsNullOrWhiteSpace(_domain)
                || string.IsNullOrWhiteSpace(from) || string.IsNullOrWhiteSpace(to))
            {
                return;
            }

            using var client = new HttpClient();
            var basic = Convert.ToBase64String(Encoding.ASCII.GetBytes("api:" + _apiKey));
            client.DefaultRequestHeaders.Authorization =
                new System.Net.Http.Headers.AuthenticationHeaderValue("Basic", basic);

            var form = new FormUrlEncodedContent(new List<KeyValuePair<string, string>>
            {
                new("from", from),
                new("to", to),
                new("subject", subject ?? string.Empty),
                new("text", text ?? string.Empty),
            });

            var url = $"{_baseUrl}/{_domain}/messages";
            try
            {
                var response = await client.PostAsync(url, form, ct);
                if (!response.IsSuccessStatusCode)
                {
                    var body = await response.Content.ReadAsStringAsync(ct);
                    _logger.Error("Mailgun send failed: {Status} {Body}", response.StatusCode, body);
                }
            }
            catch (Exception e)
            {
                _logger.Error(e, "Mailgun send exception");
            }
        }
    }
}
