export default class extends HTMLElement {
  connectedCallback () {
    if (!navigator.geolocation) return
    navigator.geolocation.getCurrentPosition(
      (position) => {
        const input = this.querySelector('input') || document.createElement('input')
        input.type = 'hidden'
        input.name = this.dataset.name || 'geolocation'
        input.value = JSON.stringify({
          latitude: position.coords.latitude,
          longitude: position.coords.longitude,
          accuracy: position.coords.accuracy
        })
        if (!input.parentNode) this.appendChild(input)
      },
      () => {}
    )
  }
}
