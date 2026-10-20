# MNC Concept

A menu and loyalty app for MNC Concept, a café in Poland. Customers browse the menu, collect points and show their loyalty code to staff.

This is the original mobile project that later became a foundation for [Smaklo](https://github.com/zielinskimarcin/smaklo-showcase), my shared platform for branded restaurant and café apps. The companion web dashboard is in [mnc-admin](https://github.com/zielinskimarcin/mnc-admin).

<table>
  <tr>
    <td><a href="https://github.com/user-attachments/assets/47461181-d631-4669-ac8d-69fe5fe28d2f"><img src="https://github.com/user-attachments/assets/47461181-d631-4669-ac8d-69fe5fe28d2f" alt="The MNC Concept menu, grouped into matcha, drinks and food categories" width="140"></a></td>
    <td><a href="https://github.com/user-attachments/assets/3d0bab5d-87eb-4f27-82e8-0949d2371828"><img src="https://github.com/user-attachments/assets/3d0bab5d-87eb-4f27-82e8-0949d2371828" alt="The loyalty screen showing four points collected toward a ten-point reward" width="140"></a></td>
  </tr>
</table>

*Screenshots of the original MNC interface.*

## Why I built it

I built the app to give the café a simple mobile menu and a digital loyalty card in its own visual style. The customer side needed to be quick to understand: see the menu, check the points balance and open a code when speaking to staff.

The other half was an owner dashboard. Menu edits, point adjustments and promotional notifications needed a workflow outside the mobile app. The two projects share a Supabase backend.

## Using it

Customers can browse categories and menu sections, create an account, view their balance and open their loyalty code. Staff use that code in the dashboard to add or remove points and redeem a reward.

The menu is stored in the database rather than bundled into each app release. The mobile screen loads it when opened and supports pull-to-refresh, so an owner can change menu data without shipping new native code.

The notification flow includes device token registration, immediate and scheduled push infrastructure, and tracking when a notification is opened. These are backend and device features; they need their own service configuration and physical-device testing.

## From one café to a reusable template

As I expanded the project, I moved brand details into a client configuration: name, colors, typography, menu categories, loyalty copy and native app identity. The Expo configuration and the application read the same client definition, which helps keep a build's bundle ID and its in-app branding aligned.

The early deployment model uses a separate Supabase project and dashboard deployment for each restaurant, while sharing the core mobile code. That trades some provisioning work for simpler data isolation between the first clients.

```text
Mobile app  ---- accounts, menu and loyalty ---- Supabase
                                                   |
Owner dashboard ---- menu, points and push ---------'
```

The later shared platform, runtime previews and demo workflow are described in the [Smaklo showcase](https://github.com/zielinskimarcin/smaklo-showcase). This repository documents the earlier mobile foundation; it is not a separate competing product.

## Built with

- **React Native, TypeScript and Expo** for the iPhone app.
- **Supabase Auth and PostgreSQL** for accounts, menu and loyalty data.
- **Supabase Edge Functions** for push registration, sending, scheduled jobs, open tracking and account deletion.
- **Expo Notifications** for the device-side push integration.
- **TestFlight** for testing the initial iOS app.

## Working with the source

The repository contains the mobile application, client configuration, Supabase migrations/functions and setup scripts. Use your own backend configuration when running a copy.

```bash
npm install
npm run typecheck
npm run client:validate -- mozzi
```

`mozzi` is a demonstration fixture, not a customer. Set `EXPO_PUBLIC_SUPABASE_URL` and `EXPO_PUBLIC_SUPABASE_ANON_KEY` for your own Supabase project, then start the configured fixture:

```bash
APP_CLIENT=mozzi EXPO_PUBLIC_CLIENT_SLUG=mozzi npm run start
```

Client configuration lives in `clients/<slug>/client.config.json`. The [client factory guide](docs/client-factory.md) explains the configuration and shared-code boundary. The [launch runbook](docs/client-launch-runbook.md) covers backend setup, auth providers, device checks and TestFlight; the [clone runbook](docs/clone-runbook.md) covers the broader smoke-test flow.

For a structural readiness report:

```bash
npm run client:readiness -- mozzi
```

The full launch checker also expects the companion dashboard checkout and relevant development tools:

```bash
npm run client:launch-check -- mozzi --full
```
