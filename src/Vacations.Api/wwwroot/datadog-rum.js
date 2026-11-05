(function (h, o, u, n, d) {
  h = h[d] = h[d] || { q: [], onReady: function (c) { h.q.push(c); } };
  d = o.createElement(u); d.async = 1; d.src = n;
  n = o.getElementsByTagName(u)[0]; n.parentNode.insertBefore(d, n);
})(window, document, 'script', 'https://www.datadoghq-browser-agent.com/us1/v6/datadog-rum.js', 'DD_RUM');

var ddConfig = window.__DD_RUM__ || {};
if (ddConfig.applicationId && ddConfig.clientToken) {
  window.DD_RUM.onReady(function () {
    window.DD_RUM.init({
      applicationId: ddConfig.applicationId,
      clientToken: ddConfig.clientToken,
      site: 'datadoghq.com',
      service: 'vacations-web',
      env: 'demo',
      sessionSampleRate: 100,
      sessionReplaySampleRate: 100,
      trackResources: true,
      trackUserInteractions: true,
      trackLongTasks: true,
      defaultPrivacyLevel: 'mask-user-input',
      // Propagate trace context to our own .NET API so RUM resources link to its APM traces (service vacations-api).
      allowedTracingUrls: [function (url) { return url.indexOf(window.location.origin + '/api/') === 0; }]
    });
  });
}
