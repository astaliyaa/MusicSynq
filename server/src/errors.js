/** An error that maps directly onto an HTTP response: `{ error: { code, message } }`. */
export class ApiError extends Error {
  constructor(status, code, message) {
    super(message);
    this.status = status;
    this.code = code;
  }
}

export const badRequest = (code, message) => new ApiError(400, code, message);
export const unauthorized = (message = "Sign in to continue.") => new ApiError(401, "unauthorized", message);
export const forbidden = (code, message) => new ApiError(403, code, message);
export const notFound = (code, message) => new ApiError(404, code, message);
export const conflict = (code, message) => new ApiError(409, code, message);
export const tooManyRequests = (message) => new ApiError(429, "rate_limited", message);
