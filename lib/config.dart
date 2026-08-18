// Public by design -- protected by Row Level Security (see
// barkod-tarayici/supabase/schema.sql), not by keeping this secret.
const supabaseUrl = 'https://ioguubjvmpfaqshwrkvd.supabase.co';
const supabaseAnonKey =
    'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImlvZ3V1Ymp2bXBmYXFzaHdya3ZkIiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODY5OTg0MTksImV4cCI6MjEwMjU3NDQxOX0.xth9KAYw4s8Wsppi24d6d5yjkUYa_pFuWZJyDsTUNRU';

// Single shared staff account -- see MEMORY notes for how it was created via
// the Supabase Admin Auth API. Not per-user; matches the store's one-password
// model instead of individual staff logins.
const sharedStaffEmail = 'personel@barkod-tarayici.local';
