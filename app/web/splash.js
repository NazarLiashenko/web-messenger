// Removes the loading splash from index.html once Flutter has drawn its first frame.
// A separate file (not an inline script) so the Content-Security-Policy can forbid inline scripts.
window.addEventListener('flutter-first-frame', function () {
  var splash = document.getElementById('splash');
  if (splash) splash.remove();
});
