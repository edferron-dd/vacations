using Vacations.Api;

var builder = WebApplication.CreateBuilder(args);

builder.Services.AddProblemDetails();
builder.Services.AddSingleton<VacationStore>();
builder.Services.AddHttpClient("chatbot", client =>
{
    client.BaseAddress = new Uri(builder.Configuration["Chatbot:BaseUrl"] ?? "http://127.0.0.1:8001");
    client.Timeout = TimeSpan.FromMinutes(3);
});
builder.Services.AddHttpClient<ForecastClient>(client =>
{
    // Left unset when the function isn't deployed; the forecast endpoint then answers 503.
    if (builder.Configuration["Forecast:BaseUrl"] is { Length: > 0 } baseUrl)
        client.BaseAddress = new Uri(baseUrl.TrimEnd('/') + "/");
    if (builder.Configuration["Forecast:FunctionKey"] is { Length: > 0 } key)
        client.DefaultRequestHeaders.Add("x-functions-key", key);
    client.Timeout = TimeSpan.FromSeconds(30);   // a cold start on Flex Consumption can take several seconds
});

var app = builder.Build();

app.UseExceptionHandler();
app.UseStatusCodePages();
app.UseDefaultFiles();
// Revalidate on every load (cheap 304 via ETag) so browsers pick up UI changes right after a deploy.
app.UseStaticFiles(new StaticFileOptions
{
    OnPrepareResponse = ctx => ctx.Context.Response.Headers.CacheControl = "no-cache",
});

app.MapVacationApi();

// On IIS, web.config's URL Rewrite rule proxies /chat/* to the Python chatbot before requests
// reach this app. For local `dotnet run` there is no IIS, so forward those requests ourselves.
if (app.Environment.IsDevelopment())
{
    app.Map("/chat/{**path}", async (HttpContext context, IHttpClientFactory factory) =>
    {
        var request = new HttpRequestMessage(new HttpMethod(context.Request.Method),
            context.Request.Path + context.Request.QueryString);
        if (context.Request.ContentLength > 0 || context.Request.Headers.TransferEncoding.Count > 0)
        {
            request.Content = new StreamContent(context.Request.Body);
            if (context.Request.ContentType is { } contentType) request.Content.Headers.TryAddWithoutValidation("Content-Type", contentType);
        }

        using var response = await factory.CreateClient("chatbot").SendAsync(request, context.RequestAborted);
        context.Response.StatusCode = (int)response.StatusCode;
        context.Response.ContentType = response.Content.Headers.ContentType?.ToString();
        await response.Content.CopyToAsync(context.Response.Body, context.RequestAborted);
    });
}

app.Run();
