// Vercel API Route: /api/verify-license
// Drop this file into your Vercel project at: api/verify-license.js
// It proxies Gumroad license validation so the plugin can verify keys securely.

export default async function handler(req, res) {
  // Allow plugin to call this endpoint
  res.setHeader("Access-Control-Allow-Origin", "*");
  res.setHeader("Access-Control-Allow-Methods", "POST, OPTIONS");
  res.setHeader("Access-Control-Allow-Headers", "Content-Type");

  if (req.method === "OPTIONS") {
    return res.status(200).end();
  }

  if (req.method !== "POST") {
    return res.status(405).json({ success: false, error: "Method not allowed" });
  }

  const { license_key } = req.body;

  if (!license_key || typeof license_key !== "string" || license_key.trim() === "") {
    return res.status(400).json({ success: false, error: "Missing license key" });
  }

  try {
    const gumroadRes = await fetch("https://api.gumroad.com/v2/licenses/verify", {
      method: "POST",
      headers: { "Content-Type": "application/x-www-form-urlencoded" },
      body: new URLSearchParams({
        product_id: "NaQbZOCQeTdF7RyKgqvgXA==",
        license_key: license_key.trim(),
        increment_uses_count: "false"
      })
    });

    const data = await gumroadRes.json();

    if (data.success) {
      return res.status(200).json({ success: true });
    } else {
      return res.status(200).json({ success: false, error: "Invalid license key" });
    }
  } catch (err) {
    console.error("Gumroad verify error:", err);
    return res.status(500).json({ success: false, error: "Verification failed, try again" });
  }
}
