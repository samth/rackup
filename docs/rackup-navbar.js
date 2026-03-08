// Inject the rackup site navbar at the top of the page.
(function () {
  var nav = document.createElement("div");
  nav.className = "rackup-navbar";
  nav.innerHTML = [
    '<a class="logo" href="https://samth.github.io/rackup/">rackup</a>',
    '<a href="docs.html">Docs</a>',
    '<a href="https://samth.github.io/rackup/install.sh">install.sh</a>',
    '<a href="https://github.com/samth/rackup">GitHub</a>',
    '<a href="https://github.com/samth/rackup/blob/main/README.md">README</a>'
  ].join("");
  document.body.insertBefore(nav, document.body.firstChild);
})();
