import { FetchOptions, $fetch as ohMyFetch } from "ofetch";
import { getAuthToken } from "utils/authStorage";

const apiBaseURL = import.meta.env.VITE_BASE_API || "/api/";

export const $fetch = ohMyFetch.create({
  baseURL: apiBaseURL,
});

export const fetcher = <T = any>(
  url: string,
  ops: FetchOptions<"json"> = {}
) => {
  const token = getAuthToken();
  if (token) {
    ops["headers"] = {
      ...(ops?.headers || {}),
      Authorization: `Bearer ${getAuthToken()}`,
    };
  }
  return $fetch<T>(url, ops);
};

export const fetch = fetcher;
