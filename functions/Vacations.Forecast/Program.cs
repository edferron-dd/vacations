using Azure.Monitor.OpenTelemetry.Exporter;
using Microsoft.Azure.Functions.Worker.Builder;
using Microsoft.Azure.Functions.Worker.OpenTelemetry;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Hosting;
using OpenTelemetry;
using OpenTelemetry.Metrics;
using OpenTelemetry.Trace;
using Vacations.Forecast;

var builder = FunctionsApplication.CreateBuilder(args);
builder.ConfigureFunctionsWebApplication();

// Request spans come from the Functions defaults, Open-Meteo calls from HttpClient instrumentation (dependencies),
// and the packing-list span and forecast counter from this app's own ActivitySource and Meter.
var otel = builder.Services.AddOpenTelemetry()
    .UseFunctionsWorkerDefaults()
    .WithTracing(tracing => tracing.AddHttpClientInstrumentation().AddSource(Telemetry.SourceName))
    .WithMetrics(metrics => metrics.AddMeter(Telemetry.MeterName));
// Exports logs, traces and metrics; without a connection string (local runs) nothing is exported.
if (!string.IsNullOrEmpty(Environment.GetEnvironmentVariable("APPLICATIONINSIGHTS_CONNECTION_STRING")))
    otel.UseAzureMonitorExporter();

builder.Services.AddMemoryCache();
builder.Services.AddHttpClient<OpenMeteoClient>(client => client.Timeout = TimeSpan.FromSeconds(10));

builder.Build().Run();
