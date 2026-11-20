<h1 align="center" style="border-bottom: none">
  <div>
    <a href="https://www.docuseal.com">
      <img  alt="DocuSeal" src="https://github.com/user-attachments/assets/38b45682-ffa4-4919-abde-d2d422325c44" width="80" />
      <br>
    </a>
    DocuSeal
  </div>
</h1>
<h3 align="center">
  Open source document filling and signing
</h3>
<p align="center">
  <a href="https://hub.docker.com/r/docuseal/docuseal">
    <img alt="Docker releases" src="https://img.shields.io/docker/v/docuseal/docuseal">
  </a>
  <a href="https://discord.gg/qygYCDGck9">
    <img src="https://img.shields.io/discord/1125112641170448454?logo=discord"/>
  </a>
  <a href="https://twitter.com/intent/follow?screen_name=docusealco">
    <img src="https://img.shields.io/twitter/follow/docusealco?style=social" alt="Follow @docusealco" />
  </a>
</p>
<p>
DocuSeal is an open source platform that provides secure and efficient digital document signing and processing. Create PDF forms to have them filled and signed online on any device with an easy-to-use, mobile-optimized web tool.
</p>
<h2 align="center">
  <a href="https://demo.docuseal.tech">✨ Live Demo</a>
  <span>|</span>
  <a href="https://docuseal.com/sign_up">☁️ Try in Cloud</a>
</h2>

[![Demo](https://github.com/user-attachments/assets/8344a341-96cf-4df3-aaae-5458a21a65b3)](https://demo.docuseal.tech)

> **This is a modified fork of [DocuSeal](https://github.com/docusealco/docuseal), not the original.**
> It is maintained by Dhruvanta Sign maintainers under the name *Dhruvanta Sign*, and is licensed under
> AGPL-3.0 with upstream's Section 7(b) additional terms (original DocuSeal attribution must stay visible in
> the user interface). It is not affiliated with or endorsed by DocuSeal LLC. The complete source of this
> version is this repository (also linked as "Source code" in the application footer and signer pages;
> override the link with the `SOURCE_CODE_URL` environment variable).

## What differs from upstream DocuSeal

Based on upstream `master` at commit `a628dd30`. Added or changed here:

| Area | Change |
| --- | --- |
| Branding | Product shown as "Dhruvanta Sign"; DocuSeal attribution and a source-code link kept on signer pages and the admin footer |
| Approvals and access | Approval chains |
| Sending | Bulk send; submitter reminders; document expiry warnings; embed form |
| Signing | Voice consent, video KYC, geolocation capture, identity verification |
| Plans | Subscriptions, analytics, SMS/WhatsApp settings, all user roles enabled; optional external plan service |
| Integrations (all off until configured, see [docs/integrations.md](docs/integrations.md)) | Generic JWT single sign-on; HTTP mail API with OAuth2 client credentials; outbound webhook outbox; service-JWT audit-events export |
| Security | Default Content-Security-Policy; signer URLs return 404 instead of redirecting to setup |
| Not included | No offline service worker; no payment provider is bundled (the payment field behaves as in upstream) |

## Features
- PDF form fields builder (WYSIWYG)
- 12 field types available (Signature, Date, File, Checkbox etc.)
- Multiple submitters per document
- Automated emails via SMTP
- Files storage on disk or AWS S3, Google Storage, Azure Cloud
- Automatic PDF eSignature
- PDF signature verification
- User management
- Mobile-optimized signing
- 7 UI languages with signing available in 14 languages
- API and Webhooks for integrations
- Easy to deploy in minutes
- Mobile apps for [iOS](https://apps.apple.com/us/app/docuseal-e-signature/id6823564236) and [Android](https://play.google.com/store/apps/details?id=com.docuseal.app)

## Pro Features
- Company logo and white-label
- User roles
- Automated reminders
- Invitation and identity verification via SMS
- Conditional fields and formulas
- Bulk send with CSV, XLSX spreadsheet import
- SSO / SAML
- Template creation with HTML API ([Guide](https://www.docuseal.com/guides/create-pdf-document-fillable-form-with-html-api))
- Template creation with PDF or DOCX and field tags API ([Guide](https://www.docuseal.com/guides/use-embedded-text-field-tags-in-the-pdf-to-create-a-fillable-form))
- Embedded signing form ([React](https://github.com/docusealco/docuseal-react), [Vue](https://github.com/docusealco/docuseal-vue), [Angular](https://github.com/docusealco/docuseal-angular) or [JavaScript](https://www.docuseal.com/docs/embedded))
- Embedded document form builder ([React](https://github.com/docusealco/docuseal-react), [Vue](https://github.com/docusealco/docuseal-vue), [Angular](https://github.com/docusealco/docuseal-angular) or [JavaScript](https://www.docuseal.com/docs/embedded))
- [Learn more](https://www.docuseal.com/pricing)

## Deploy

|Heroku|Railway|
|:--:|:---:|
| [<img alt="Deploy on Heroku" src="https://www.herokucdn.com/deploy/button.svg" height="40">](https://heroku.com/deploy?template=https://github.com/docusealco/docuseal-heroku) | [<img alt="Deploy on Railway" src="https://railway.app/button.svg" height="40">](https://railway.com/deploy/IGoDnc?referralCode=ruU7JR)|
|**DigitalOcean**|**Render**|
| [<img alt="Deploy on DigitalOcean" src="https://www.deploytodo.com/do-btn-blue.svg" height="40">](https://cloud.digitalocean.com/apps/new?repo=https://github.com/docusealco/docuseal-digitalocean/tree/master&refcode=421d50f53990) | [<img alt="Deploy to Render" src="https://render.com/images/deploy-to-render-button.svg" height="40">](https://render.com/deploy?repo=https://github.com/docusealco/docuseal-render)

#### Docker

```sh
docker run --name docuseal -p 3000:3000 -v.:/data docuseal/docuseal
```

By default DocuSeal docker container uses an SQLite database to store data and configurations. Alternatively, it is possible to use PostgreSQL or MySQL databases by specifying the `DATABASE_URL` env variable.

#### Docker Compose

Download docker-compose.yml into your private server:
```sh
curl https://raw.githubusercontent.com/docusealco/docuseal/master/docker-compose.yml > docker-compose.yml
```

Run the app under a custom domain over https using docker compose (make sure your DNS points to the server to automatically issue ssl certs with Caddy):
```sh
sudo HOST=your-domain-name.com docker compose up
```

## For Businesses
### Integrate seamless document signing into your web or mobile apps with DocuSeal

At DocuSeal we have expertise and technologies to make documents creation, filling, signing and processing seamlessly integrated with your product. We specialize in working with various industries, including **Banking, Healthcare, Transport, Real Estate, eCommerce, KYC, CRM, and other software products** that require bulk document signing. By leveraging DocuSeal, we can assist in reducing the overall cost of developing and processing electronic documents while ensuring security and compliance with local electronic document laws.

[Book a Meeting](https://www.docuseal.com/contact)

## License

Distributed under the AGPLv3 License with Section 7(b) Additional Terms. See [LICENSE](LICENSE) and [LICENSE_ADDITIONAL_TERMS](LICENSE_ADDITIONAL_TERMS) for more information.
Unless otherwise noted, files originating from upstream are © 2023-2026 DocuSeal LLC; modifications in this fork are released under the same license.

### Trademarks

The names "Dhruvanta Sign" and "Dhruvanta" and the Dhruvanta logo are trademarks of their owners and are
not licensed under the AGPL. The AGPL grants rights to the source code only. Do not use these names or
the logo for a modified version in a way that suggests it is the original. DocuSeal's own names and marks
belong to DocuSeal LLC.

## Tools

- [Signature Maker](https://www.docuseal.com/online-signature)
- [Sign Document Online](https://www.docuseal.com/sign-documents-online)
- [Fill PDF Online](https://www.docuseal.com/fill-pdf)
