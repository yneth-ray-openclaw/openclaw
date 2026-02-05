/** Default Telegram Bot API root URL. */
export const DEFAULT_TELEGRAM_API_ROOT = "https://api.telegram.org";

/**
 * Resolves the Telegram API root URL from config or environment.
 * Priority: config.apiRoot > OPENCLAW_TELEGRAM_API_ROOT env > default
 */
export function resolveApiRoot(config?: { apiRoot?: string }): string {
  const fromConfig = config?.apiRoot?.trim();
  if (fromConfig) {
    return fromConfig.replace(/\/$/, "");
  }
  const fromEnv = process.env.OPENCLAW_TELEGRAM_API_ROOT?.trim();
  if (fromEnv) {
    return fromEnv.replace(/\/$/, "");
  }
  return DEFAULT_TELEGRAM_API_ROOT;
}
