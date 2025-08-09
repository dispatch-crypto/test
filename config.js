// config.js

// --- SUPABASE CONFIGURATION ---
// This file connects to your database.
// Replace the key below with your actual Supabase Anon Key.

const SUPABASE_URL = 'https://jyzbdkuizwvqamsxqdfg.supabase.co';
const SUPABASE_ANON_KEY = 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Imp5emJka3Vpend2cWFtc3hxZGZnIiwicm9sZSI6ImFub24iLCJpYXQiOjE3NTQ0MTE2MzUsImV4cCI6MjA2OTk4NzYzNX0.AqcKHtGPjm5fSijgjh8CMzrqRuheDRAefyU0prPwY2I';

// This creates the 'db' client that all other pages will use.
const db = supabase.createClient(SUPABASE_URL, SUPABASE_ANON_KEY);
