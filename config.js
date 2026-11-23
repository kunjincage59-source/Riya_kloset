/*
  Riy@ Kloset: Supabase connection
  ---------------------------------
  Supabase dashboard → Project Settings → API (or "Data API")
    • Project URL           → supabaseUrl
    • anon / public key     → supabaseAnonKey   (the "publishable" key)

  The anon key is SAFE to be public: the database rules (Row Level Security in
  supabase-setup.sql) only let visitors READ active products, and only admins
  can add, edit or delete anything.
  NEVER put the "service_role" / secret key here.

  Leave the placeholders as they are to run the site in demo mode.
*/
window.RK_CONFIG = {
  supabaseUrl: "https://iujmotvzdksweyhheihb.supabase.co",
  supabaseAnonKey: "sb_publishable_ddBSt8z8LCSZcbwHO9tK3A_YLtTmjLD"
};
