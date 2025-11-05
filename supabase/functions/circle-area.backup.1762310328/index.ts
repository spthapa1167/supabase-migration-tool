// Edge Function: circle-area
// Calculate the area of a circle given radius

import { serve } from "https://deno.land/std@0.168.0/http/server.ts"

serve(async (req) => {
  try {
    const { radius } = await req.json()
    
    if (!radius || typeof radius !== 'number' || radius <= 0) {
      return new Response(
        JSON.stringify({ error: 'Invalid radius. Must be a positive number.' }),
        { 
          status: 400,
          headers: { 'Content-Type': 'application/json' }
        }
      )
    }
    
    const area = Math.PI * radius * radius
    
    return new Response(
      JSON.stringify({ 
        radius,
        area,
        formula: 'π × r²'
      }),
      { 
        headers: { 'Content-Type': 'application/json' }
      }
    )
  } catch (error) {
    return new Response(
      JSON.stringify({ error: error.message }),
      { 
        status: 500,
        headers: { 'Content-Type': 'application/json' }
      }
    )
  }
})
