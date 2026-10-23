# Connect QuickBooks Online

You need an Intuit developer app, which you create once and reuse for every connection,
and admin access to the QuickBooks company you connect.

## 1. Create an Intuit app

1. Sign in at the [Intuit Developer portal](https://developer.intuit.com) and create an
   app for **QuickBooks Online and Payments**.
2. When asked for permissions (scopes), select **Accounting**
   (`com.intuit.quickbooks.accounting`).
3. Intuit creates a sandbox company for you. Find its company ID under **Sandbox** in the
   portal; it is a long number.

## 2. Add the connection in Houston

1. Start adding the QuickBooks Online connection. Houston shows a **callback URL**: copy it.
2. In the Intuit portal, open your app's **Settings** (or **Keys and credentials**) for
   the environment you use, add the callback URL under **Redirect URIs**, and save.
3. Back in Houston, choose:
   - **Access**: **Read-only** to start, or **Read and write**.
   - **Environment**: **Sandbox** with the app's Development keys, or **Production** with
     its Production keys.
   - **QuickBooks company ID (Realm ID)**: the sandbox company ID, or your real company's ID.
4. Copy the app's **Client ID** and **Client Secret** from **Keys and credentials** into
   **Intuit app client ID** and **Intuit app client secret**.
5. Select **Connect with Intuit**, sign in, and choose the same company you entered.

Each connection reaches one company. Add another connection for another company, or to
move from the sandbox to production.

## Advanced

### Use your real company (production)

Intuit gives an app Production keys after you complete the production questionnaire on
its **Keys and credentials** page. Add Houston's callback URL to the production
**Redirect URIs** too, then set **Environment** to **Production** and enter the Production
client ID and secret. Find your company ID in QuickBooks under **Settings → Account and
settings → Billing & subscription**, listed as **Company ID**. See Intuit's
[app setup guide](https://developer.intuit.com/app/developer/qbo/docs/get-started).

### Troubleshooting

- **Redirect URI error during sign-in**: the callback URL Houston shows is missing from the
  app's Redirect URIs for that environment, or was copied with extra spaces.
- **401 AUTHENTICATION (3200)**: the sign-in expired or was disconnected in QuickBooks.
  Select **Set up again** and sign in.
- **403 or "ApplicationAuthorizationFailed" (003100)**: the company ID doesn't match the
  company you signed in to, or Development keys were used against a production company.
  Check **Environment**, the keys and the company ID.
- Intuit asks apps to sign in again at least every 100 days; Houston refreshes the sign-in
  automatically while the connection is used.
