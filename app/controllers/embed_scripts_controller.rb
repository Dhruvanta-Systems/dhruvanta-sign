# frozen_string_literal: true

class EmbedScriptsController < ActionController::Metal
  EMBED_SCRIPT = <<~JAVASCRIPT
    class DocusealForm extends HTMLElement {
      connectedCallback() {
        const slug = this.getAttribute('data-slug');
        const host = this.getAttribute('data-host') || '';
        if (!slug) { this.innerHTML = '<p>Error: data-slug is required</p>'; return; }
        const iframe = document.createElement('iframe');
        iframe.src = host + '/embed/form/' + slug;
        iframe.style.cssText = 'width:100%;border:none;min-height:600px;';
        iframe.setAttribute('allow', 'camera;microphone');
        this.appendChild(iframe);
        window.addEventListener('message', (e) => {
          if (e.source !== iframe.contentWindow) return;
          if (e.data && e.data.type === 'docuseal:resize') iframe.style.height = e.data.height + 'px';
          if (e.data && e.data.type === 'docuseal:completed') this.dispatchEvent(new CustomEvent('completed', { detail: e.data }));
        });
      }
    }
    if (!window.customElements.get('docuseal-form')) window.customElements.define('docuseal-form', DocusealForm);
  JAVASCRIPT

  def show
    headers['Content-Type'] = 'application/javascript'

    self.response_body = EMBED_SCRIPT

    self.status = 200
  end
end
