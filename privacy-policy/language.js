(() => {
  const requestedLanguage = new URLSearchParams(window.location.search).get("lang");

  if (requestedLanguage !== "ja") {
    document.documentElement.lang = "en";
    document.documentElement.classList.remove("language-loading");
    return;
  }

  fetch("ja.html")
    .then((response) => {
      if (!response.ok) {
        throw new Error(`Japanese translation could not be loaded (${response.status}).`);
      }
      return response.text();
    })
    .then((html) => {
      const translatedDocument = new DOMParser().parseFromString(html, "text/html");
      const translatedDescription = translatedDocument.querySelector(
        'meta[name="description"]'
      );
      const currentDescription = document.querySelector('meta[name="description"]');

      document.title = translatedDocument.title;
      if (translatedDescription && currentDescription) {
        currentDescription.content = translatedDescription.content;
      }
      document.body.replaceWith(translatedDocument.body);
      document.documentElement.lang = "ja";
    })
    .catch((error) => {
      console.error(error);
      document.documentElement.lang = "en";
    })
    .finally(() => {
      document.documentElement.classList.remove("language-loading");
      window.dispatchEvent(new CustomEvent("eagle-inbox:language-ready"));
    });
})();
