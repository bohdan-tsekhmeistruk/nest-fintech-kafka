import path from 'path';
import winston from 'winston';
import DailyRotateFile from 'winston-daily-rotate-file';

const logsDir = 'logs';
const maxSize = '20m';

const format = winston.format.combine(
  winston.format.colorize(),
  winston.format.splat(),
  winston.format.errors({ stack: true }),
  winston.format.json(),
  winston.format.timestamp({
    format: 'YYYY-MM-DD HH:mm:ss',
  }),
  winston.format.printf(({ level, message, timestamp, context }) => {
    const messageString: string =
      typeof message === 'object'
        ? JSON.stringify(message)
        : (message as string);
    return `${timestamp as string} ${level} [${(context as string) ?? 'Unknown context'}] ${messageString}`;
  }),
);

export default winston.createLogger({
  level: 'info',
  format,
  defaultMeta: { service: 'transactions-service' },
  transports: [
    new winston.transports.Console(),
    new DailyRotateFile({
      filename: '%DATE%.log',
      datePattern: 'YYYY-MM/DD',
      dirname: logsDir,
      auditFile: path.join(logsDir, 'audit-info.json'),
      zippedArchive: false,
      maxSize,
      maxFiles: '14d',
      level: 'info',
      format: winston.format.json(),
    }),

    new DailyRotateFile({
      filename: '%DATE%-error.log',
      datePattern: 'YYYY-MM/DD',
      dirname: logsDir,
      auditFile: path.join(logsDir, 'audit-error.json'),
      maxSize,
      maxFiles: '30d',
      level: 'error',
      format: winston.format.json(),
    }),
  ],
});
