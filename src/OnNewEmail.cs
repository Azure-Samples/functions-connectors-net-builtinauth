using Microsoft.Azure.Functions.Worker;
using Microsoft.Azure.Functions.Worker.Extensions.Connector;
using Microsoft.Extensions.Logging;
using Azure.Connectors.Sdk.Office365.Models;
using System.Text.Json;

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
        _logger.LogInformation("Received Microsoft 365 OnNewEmail trigger");

        try
        {
            // Log the email details
            if (emailPayload?.Body?.Value != null && emailPayload.Body.Value.Count > 0)
            {
                _logger.LogInformation("Email received from: {From}", emailPayload.Body.Value[0].From);
                _logger.LogInformation("Email subject: {Subject}", emailPayload.Body.Value[0].Subject);
            }

            // Optionally, log the entire payload as JSON for debugging
            var payloadJson = JsonSerializer.Serialize(emailPayload, new JsonSerializerOptions { WriteIndented = true });
            _logger.LogInformation("Full payload: {PayloadJson}", payloadJson);
        }
        catch (Exception ex)
        {
            _logger.LogError(ex, "Failed to process email");
        }
    }
}