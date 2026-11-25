# saml2aws-setup

Sign in to AWS through Okta from Windows (WSL) without retyping your details every time.

- **AWS Login**: signs you in to an AWS environment (dev, test, mgmt, prod, …) so the AWS CLI works.
- **AWS Database Password**: signs you in, then gives you a 15-minute database password
  (RDS IAM token) and copies it to the clipboard.

The first time you use an environment you paste its Okta link and type your username and
password. After that, each is remembered **per environment**:

| What | Where it is kept |
| --- | --- |
| Okta link and username | `~/.saml2aws` (one section per environment) |
| Password | `~/.config/samllogin/passwords/<env>.dpapi`, encrypted with Windows DPAPI so only your Windows login can read it |
| Database hostname | `~/.config/samllogin/hosts` |

You still approve the Okta Verify prompt on your phone each time.

## Install (Windows with WSL)

1. Open **Ubuntu** from the Start menu.
2. Paste these lines and press Enter:

   ```bash
   git clone https://github.com/GSA/saml2aws-setup.git
   cd saml2aws-setup && ./install.sh
   ```

3. For each environment, answer **Y** and paste its Okta link when asked. To get the link,
   open your Okta dashboard, right-click the AWS tile for that environment, and choose
   **Copy link**. Use your own links and never copy someone else's `~/.saml2aws`.
4. Two shortcuts appear on your Desktop: **AWS Login** and **AWS Database Password**.

You can delete the `saml2aws-setup` folder afterwards; the installer copies what it needs to
`~/.local/share/saml2aws-setup`.

## Use

Double-click a Desktop shortcut and pick the environment, or run it from a terminal:

```bash
awslogin.sh mgmt                  # then: aws --profile mgmt ...
samllogin.sh prod                 # prints a database password; samllogin.sh prod readonly for another DB user
samllogin.sh --list               # saved database hostnames
```

If your password changes, sign-in fails once and you're asked for the new one, which replaces
the saved one.

## Change or remove saved details

| To | Do |
| --- | --- |
| Change an environment's Okta link or username | Delete its section from `~/.saml2aws`; you'll be asked again |
| Forget a saved password | `rm ~/.config/samllogin/passwords/<env>.dpapi` |
| Never save passwords | `export SAMLLOGIN_NO_SAVE=1` |
| Change a database hostname | Type a new one at the prompt (Enter keeps the saved one) |

`saml2aws.example` shows what `~/.saml2aws` looks like, with placeholders.

## Notes

- Outside WSL, passwords are saved in the desktop keyring if `secret-tool` is installed;
  otherwise you're asked each time.
- Sessions last 8 hours, or 1 hour for environments whose name starts with `prod`. Change
  `aws_session_duration` in `~/.saml2aws` if your role allows something else.
- The installer downloads the latest [saml2aws](https://github.com/Versent/saml2aws) release
  and checks its published SHA-256 before installing it to `~/.local/bin`.
