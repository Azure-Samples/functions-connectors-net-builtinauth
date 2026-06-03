using Microsoft.Azure.Functions.Worker;
using Microsoft.Azure.Functions.Worker.Extensions.Connector;
using Microsoft.Extensions.Logging;
using Azure.Connectors.Sdk.Office365.Models;

namespace hello_microsoft365email_connector;

public class OnNewEmail
{
    private readonly ILogger<OnNewEmail> _logger;

    public OnNewEmail(ILogger<OnNewEmail> logger)
    {
        _logger = logger;
    }

    [Function("OnNewEmail")]
    public void Run(
        [ConnectorTrigger] Office365OnNewEmailTriggerPayload emailPayload)
    {
        // If this line runs, built-in authentication already validated the caller
        // against defaultAuthorizationPolicy.allowedPrincipals at the App Service
        // edge; anything that fails that check is 401'd before the runtime ever
        // dispatches to the worker. For a connector trigger the runtime's webhook
        // endpoint consumes the HTTP request and forwards only the deserialized
        // payload, so the worker can't see the bearer token or the
        // X-MS-CLIENT-PRINCIPAL-* headers; per-call caller-oid logging from inside
        // the function isn't possible for this trigger type.
        _logger.LogInformation("OnNewEmail invoked (caller pre-validated by built-in authentication).");

        try
        {
            if (emailPayload?.Body?.Value is { Count: > 0 } emails)
            {
                _logger.LogInformation("Email received from: {From}", emails[0].From);
                _logger.LogInformation("Email subject: {Subject}", emails[0].Subject);
            }
        }
        catch (Exception ex)
        {
            _logger.LogError(ex, "Failed to process email");
        }
    }
}
