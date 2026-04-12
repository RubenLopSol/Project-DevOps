import { QueryClient } from '@tanstack/react-query';
import { createTRPCClient, httpLink } from '@trpc/client';
import { createTRPCOptionsProxy } from '@trpc/tanstack-react-query';
import superjson from 'superjson';

import { TRPCProvider } from '@/integrations/trpc/react';
import type { AppRouter } from '@openpanel/trpc';
import { createIsomorphicFn } from '@tanstack/react-start';
import { getRequestHeaders } from '@tanstack/react-start/server';
import { useMemo } from 'react';

export const getIsomorphicHeaders = createIsomorphicFn()
  .server(() => {
    return getRequestHeaders();
  })
  .client(() => {
    return {};
  });

// Create a function that returns a tRPC client with optional cookies
export function createTRPCClientWithHeaders(apiUrl: string) {
  return createTRPCClient<AppRouter>({
    links: [
      httpLink({
        transformer: superjson,
        url: `${apiUrl}/trpc`,
        headers: () => getIsomorphicHeaders(),
        fetch: async (url, options) => {
          try {
            console.log('fetching', url, options);
            const response = await fetch(url, {
              ...options,
              mode: 'cors',
              credentials: 'include',
            });

            // Log HTTP errors on server
            if (!response.ok && typeof window === 'undefined') {
              const text = await response.clone().text();
              console.error('[tRPC SSR Error]', {
                url: url.toString(),
                status: response.status,
                statusText: response.statusText,
                body: text,
                options,
              });
            }

            return response;
          } catch (error) {
            // Log fetch errors on server
            if (typeof window === 'undefined') {
              console.error('[tRPC SSR Error]', {
                url: url.toString(),
                error: error instanceof Error ? error.message : String(error),
                stack: error instanceof Error ? error.stack : undefined,
                options,
              });
            }
            throw error;
          }
        },
      }),
    ],
  });
}

export function getContext(serverApiUrl: string, clientApiUrl?: string) {
  const queryClient = new QueryClient({
    defaultOptions: {
      queries: {
        staleTime: 1000 * 60 * 5,
        gcTime: 1000 * 60 * 10,
        refetchOnReconnect: false,
      },
      dehydrate: { serializeData: superjson.serialize },
      hydrate: { deserializeData: superjson.deserialize },
    },
  });

  // Server-side: use the internal Docker URL so SSR can reach the API container.
  // Client-side: use the public URL (localhost:3333) so the browser sends the
  // session cookie — which is scoped to localhost, not host.docker.internal.
  const effectiveApiUrl =
    typeof window === 'undefined'
      ? serverApiUrl
      : (clientApiUrl || serverApiUrl);

  const client = createTRPCClientWithHeaders(effectiveApiUrl);

  const serverHelpers = createTRPCOptionsProxy({
    client: client,
    queryClient: queryClient,
  });
  return {
    queryClient,
    trpc: serverHelpers,
  };
}

export function Provider({
  children,
  queryClient,
  apiUrl,
}: {
  children: React.ReactNode;
  queryClient: QueryClient;
  // This is the client-side URL (e.g. localhost:3333).
  // It must be a URL the browser can reach, and should match the domain where
  // the session cookie will be stored so SSR can forward it correctly.
  apiUrl: string;
}) {
  const trpcClient = useMemo(
    () => createTRPCClientWithHeaders(apiUrl),
    [apiUrl],
  );
  return (
    <TRPCProvider trpcClient={trpcClient} queryClient={queryClient}>
      {children}
    </TRPCProvider>
  );
}
