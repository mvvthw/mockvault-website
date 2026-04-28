// Netlify Function: /api/verify-license
// Proxies Gumroad license validation so the plugin can verify keys securely.

const CORS_HEADERS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
  "Access-Control-Allow-Headers": "Content-Type",
  "Content-Type": "application/json",
};

exports.handler = async (event) => {
  if (event.httpMethod === "OPTIONS") {
    return { statusCode: 200, headers: CORS_HEADERS, body: "" };
  }

  if (event.httpMethod !== "POST") {
    return {
      statusCode: 405,
      headers: CORS_HEADERS,
      body: JSON.stringify({ success: false, error: "Method not allowed" }),
    };
  }

  let license_key;
  try {
    ({ license_key } = JSON.parse(event.body || "{}"));
  } catch {
    return {
      statusCode: 400,
      headers: CORS_HEADERS,
      body: JSON.stringify({ success: false, error: "Invalid JSON body" }),
    };
  }

  if (!license_key || typeof license_key !== "string" || license_key.trim() === "") {
    return {
      statusCode: 400,
      headers: CORS_HEADERS,
      body: JSON.stringify({ success: false, error: "Missing license key" }),
    };
  }

  try {
    const gumroadRes = await fetch("https://api.gumroad.com/v2/licenses/verify", {
      method: "POST",
      headers: { "Content-Type": "application/x-www-form-urlencoded" },
      body: new URLSearchParams({
        product_id: "NaQbZ0CQeTdF7RyKgqvgXA==",
        license_key: license_key.trim(),
        increment_uses_count: "false",
      }),
    });

    const data = await gumroadRes.json();
    console.log("Gumroad response:", JSON.stringify(data));

    if (data.success) {
      return {
        statusCode: 200,
        headers: CORS_HEADERS,
        body: JSON.stringify({ success: true }),
      };
    } else {
      return {
        statusCode: 200,
        headers: CORS_HEADERS,
        body: JSON.stringify({ success: false, error: data.message || "Invalid license key" }),
      };
    }
  } catch (err) {
    console.error("Gumroad verify error:", err);
    return {
      statusCode: 500,
      headers: CORS_HEADERS,
      body: JSON.stringify({ success: false, error: "Verification failed, try again" }),
    };
  }
};
