import { Controller } from "@hotwired/stimulus"

// Copies an invitation link so the admin can paste it into whatever channel
// they use to send it (the app doesn't email invitations yet).
export default class extends Controller {
  static targets = ["source", "label"]

  async copy() {
    try {
      await navigator.clipboard.writeText(this.sourceTarget.value)
      this.labelTarget.textContent = "Copied"
    } catch {
      // Clipboard access can be refused (e.g. a non-HTTPS origin other than
      // localhost); fall back to selecting the text so it can be copied by hand.
      this.select()
      this.labelTarget.textContent = "Press Ctrl+C"
    }
  }

  select() {
    this.sourceTarget.select()
  }
}
