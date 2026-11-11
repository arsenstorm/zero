// Puts the phone's search sheet on the page, open, the first time it's asked for (Base.astro's Search button).
import { createRoot } from "react-dom/client";
import SearchSheet from "./SearchSheet";

export function mount() {
  const host = document.createElement("div");
  document.body.append(host);
  createRoot(host).render(<SearchSheet startOpen />);
}
