import { StringDecoder } from 'node:string_decoder';

export function captureLaunchOutput(stream, onToken, output) {
  const decoder = new StringDecoder('utf8');
  let pending = '';
  let discard = false;
  function line(value) {
    const match = value.match(/^dsh web: http:\/\/127\.0\.0\.1:3080\/\?token=([A-Za-z0-9_-]+)\s*$/);
    if (match) {
      onToken(match[1]);
      output('dsh web: native session bootstrap ready\n');
    } else if (/token\s*=/i.test(value)) output('[DSH token-bearing output suppressed]\n');
    else output(value + '\n');
  }
  stream.on('data', chunk => {
    pending += decoder.write(chunk);
    let end;
    while ((end = pending.indexOf('\n')) >= 0) {
      const value = pending.slice(0, end);
      if (!discard && value.length <= 65536) line(value.replace(/\r$/, ''));
      pending = pending.slice(end + 1);
      discard = false;
    }
    if (pending.length > 65536) { pending = ''; discard = true; }
  });
  stream.on('end', () => {
    pending += decoder.end();
    if (pending && !discard) line(pending);
  });
}
