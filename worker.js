export default {
  async fetch(request, env, ctx) {
    const { RESEND_API_KEY, AUTH_SECRET } = env;

    // 1. Authentication Check
    const authHeader = request.headers.get('Authorization');
    if (!authHeader || authHeader !== AUTH_SECRET) {
      return new Response('Unauthorized', { status: 401 });
    }

    const url = new URL(request.url);
    const method = request.method;

    // 2. Routing
    if (method === 'POST' && url.pathname === '/send') {
      return handleSend(request, RESEND_API_KEY);
    } else if (method === 'POST' && url.pathname === '/cancel') {
      return handleCancel(request, RESEND_API_KEY);
    } else {
      return new Response('Not Found', { status: 404 });
    }
  },
};

async function handleSend(request, apiKey) {
  try {
    const body = await request.json();
    
    // Extract the raw message. 
    let userMessage = body.html || "No message provided.";
    userMessage = userMessage.replace(/<p>/g, '').replace(/<\/p>/g, '\n').trim().split('\n')[0];

    // Rebuild the HTML using RUOK? premium template (Matrix Style)
    const enhancedHtml = `
<div style="font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, Helvetica, Arial, sans-serif; max-width: 600px; margin: 0 auto; color: #1a1a1a; line-height: 1.6;">
  <div style="padding: 32px; border: 1px solid #e5e7eb; border-radius: 24px; background-color: #ffffff;">
    <!-- Header -->
    <div style="display: flex; align-items: center; margin-bottom: 24px;">
      <div style="background-color: #fee2e2; padding: 10px; border-radius: 12px; margin-right: 12px;">
        <span style="font-size: 24px;">🚨</span>
      </div>
      <h2 style="color: #dc2626; font-size: 22px; margin: 0; font-weight: 800; letter-spacing: -0.025em;">RUOK? Emergency Alert</h2>
    </div>

    <!-- Description -->
    <p style="font-size: 16px; color: #4b5563; margin-bottom: 32px;">
      This is an automated safety notification. The user has not checked into their RUOK? safety switch within the scheduled time.
    </p>

    <!-- Message Box -->
    <div style="background-color: #f9fafb; padding: 24px; border-radius: 16px; border-left: 4px solid #dc2626; margin-bottom: 40px;">
      <p style="margin: 0 0 12px 0; font-weight: 700; font-size: 12px; text-transform: uppercase; color: #9ca3af; letter-spacing: 0.1em;">Personal Message from User</p>
      <p style="margin: 0; font-size: 18px; color: #111827; font-style: italic; line-height: 1.5;">"${userMessage}"</p>
    </div>
    
    <!-- Brand Section (RUOK Branding) -->
    <div style="margin-top: 48px; border-top: 1px solid #f3f4f6; padding-top: 40px;">
      <p style="font-size: 12px; color: #9ca3af; text-align: center; margin-bottom: 24px;">Automatically delivered by RUOK? Protection System</p>
      
      <div style="background-color: #0c0a09; padding: 32px; border-radius: 20px; color: white; text-align: center; border: 1px solid #00FF41;">
        <h3 style="margin: 0; font-size: 20px; font-weight: 700; color: #00FF41;">Your Last Line of Defense</h3>
        <p style="margin: 12px 0 24px; font-size: 14px; opacity: 0.9; line-height: 1.6;">RUOK? is a dedicated safety App designed for individuals living alone. The system will automatically notify your emergency contacts if a scheduled check-in is missed beyond the set time limit, ensuring you are never truly alone in critical moments.</p>
        <a href="https://gowellapp.me" style="background-color: #00FF41; color: #000000; padding: 14px 28px; text-decoration: none; border-radius: 12px; font-weight: 700; font-size: 14px; display: inline-block;">Learn more about RUOK?</a>
      </div>
    </div>

    <!-- Footer -->
    <div style="margin-top: 32px; text-align: center;">
      <p style="font-size: 12px; color: #d1d5db; margin: 0;">&copy; 2026 RUOK? Safety Systems. All rights reserved.</p>
    </div>
  </div>
</div>
    `;

    const resendBody = {
      ...body,
      html: enhancedHtml
    };
    
    const response = await fetch('https://api.resend.com/emails', {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        'Authorization': `Bearer ${apiKey}`,
      },
      body: JSON.stringify(resendBody),
    });

    const data = await response.json();
    return new Response(JSON.stringify(data), {
      status: response.status,
      headers: { 'Content-Type': 'application/json' },
    });
  } catch (error) {
    return new Response(JSON.stringify({ error: error.message }), {
      status: 500,
      headers: { 'Content-Type': 'application/json' },
    });
  }
}

async function handleCancel(request, apiKey) {
  try {
    const body = await request.json();
    const { id } = body;

    if (!id) {
      return new Response(JSON.stringify({ error: 'Missing email ID' }), {
        status: 400,
        headers: { 'Content-Type': 'application/json' },
      });
    }

    const response = await fetch(`https://api.resend.com/emails/${id}/cancel`, {
      method: 'POST',
      headers: {
        'Authorization': `Bearer ${apiKey}`,
      },
    });

    const data = await response.json();
    return new Response(JSON.stringify(data), {
      status: response.status,
      headers: { 'Content-Type': 'application/json' },
    });
  } catch (error) {
    return new Response(JSON.stringify({ error: error.message }), {
      status: 500,
      headers: { 'Content-Type': 'application/json' },
    });
  }
}
