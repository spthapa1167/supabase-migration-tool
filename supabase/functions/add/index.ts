// Supabase Edge Function: add
// Adds two numbers from JSON body: { "a": number, "b": number }
// Returns: { sum: number }
console.info('add function started');
Deno.serve(async (req)=>{
  try {
    if (req.method !== 'POST') {
      return new Response(JSON.stringify({
        error: 'Use POST with JSON body { a, b }'
      }), {
        status: 405,
        headers: {
          'Content-Type': 'application/json'
        }
      });
    }
    const contentType = req.headers.get('content-type') || '';
    if (!contentType.includes('application/json')) {
      return new Response(JSON.stringify({
        error: 'Content-Type must be application/json'
      }), {
        status: 415,
        headers: {
          'Content-Type': 'application/json'
        }
      });
    }
    const body = await req.json();
    const a = Number(body?.a);
    const b = Number(body?.b);
    if (!Number.isFinite(a) || !Number.isFinite(b)) {
      return new Response(JSON.stringify({
        error: 'Both a and b must be valid numbers'
      }), {
        status: 400,
        headers: {
          'Content-Type': 'application/json'
        }
      });
    }
    const sum = a + b;
    return new Response(JSON.stringify({
      sum
    }), {
      headers: {
        'Content-Type': 'application/json',
        'Connection': 'keep-alive'
      }
    });
  } catch (err) {
    console.error('Unhandled error in add function:', err);
    return new Response(JSON.stringify({
      error: 'Internal Server Error'
    }), {
      status: 500,
      headers: {
        'Content-Type': 'application/json'
      }
    });
  }
});
