console.info('circle-area function started');
Deno.serve(async (req)=>{
  if (req.method !== 'POST') {
    return new Response(JSON.stringify({
      error: 'Use POST with JSON { radius }'
    }), {
      status: 405,
      headers: {
        'Content-Type': 'application/json'
      }
    });
  }
  let body;
  try {
    body = await req.json();
  } catch  {
    return new Response(JSON.stringify({
      error: 'Invalid JSON body'
    }), {
      status: 400,
      headers: {
        'Content-Type': 'application/json'
      }
    });
  }
  const r = Number(body?.radius);
  if (!Number.isFinite(r) || r < 0) {
    return new Response(JSON.stringify({
      error: 'radius must be a non-negative number'
    }), {
      status: 400,
      headers: {
        'Content-Type': 'application/json'
      }
    });
  }
  const area = Math.PI * r * r;
  return new Response(JSON.stringify({
    radius: r,
    area
  }), {
    headers: {
      'Content-Type': 'application/json',
      'Connection': 'keep-alive'
    }
  });
});
