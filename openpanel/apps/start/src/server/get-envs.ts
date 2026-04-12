import { queryOptions } from '@tanstack/react-query';
import { createServerFn } from '@tanstack/react-start';

export const getServerEnvs = createServerFn().handler(async () => {
  const envs = {
    // Used by SSR (server-side fetch inside the container).
    // Points to the internal Docker hostname so the container can reach the API
    // without going through the host machine's port mapping.
    apiUrl: String(process.env.API_URL || process.env.NEXT_PUBLIC_API_URL),
    // Used by the browser (client-side fetch).
    // Must be a URL the browser can reach — always localhost:3333 in local dev.
    // Keeping the cookie domain as localhost ensures the session cookie set by
    // the API is sent back on subsequent requests to localhost:3000 (dashboard),
    // which the SSR layer then forwards to the internal API URL above.
    clientApiUrl: String(process.env.NEXT_PUBLIC_API_URL || process.env.API_URL),
    dashboardUrl: String(
      process.env.DASHBOARD_URL || process.env.NEXT_PUBLIC_DASHBOARD_URL,
    ),
    isSelfHosted: process.env.SELF_HOSTED !== undefined,
    isMaintenance: process.env.MAINTENANCE === '1',
  };

  return envs;
});

export const getServerEnvsQueryOptions = queryOptions({
  queryKey: ['server-envs'],
  queryFn: getServerEnvs,
  staleTime: Number.POSITIVE_INFINITY,
});
