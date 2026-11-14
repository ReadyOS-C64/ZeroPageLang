if (matchMedia("(max-width: 52rem)").matches) {
  document.querySelector(".section-menu")?.removeAttribute("open");
}

for (const box of document.querySelectorAll(".codebox")) {
  if (!navigator.clipboard) break;
  const button = document.createElement("button");
  button.type = "button";
  button.textContent = "Copy";
  button.addEventListener("click", async () => {
    try {
      await navigator.clipboard.writeText(box.querySelector("code").textContent);
      button.textContent = "Copied";
    } catch {
      button.textContent = "Select code to copy";
    }
  });
  box.querySelector(".codebar").append(button);
}
