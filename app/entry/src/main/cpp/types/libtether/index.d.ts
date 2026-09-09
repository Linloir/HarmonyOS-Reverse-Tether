export const createSocket: () => number;
export const connect: (socketFd: number, port: number) => Promise<void>;
export const start: (tunFd: number, socketFd: number, session: number) => void;
export const stop: (session: number) => void;
export const close: (fd: number) => void;
export const status: (session: number) => string;
export const newSession: () => number;
