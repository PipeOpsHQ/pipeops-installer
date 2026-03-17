import { useEffect, useState } from 'react';
import { supabase } from '../lib/supabase';
import { useAuth } from '../context/AuthContext';

export type UserLocation = {
  user_id: string;
  lat: number;
  long: number;
  updated_at: string; // timestamp in DB
  avatar_url?: string; // from profile join
};

export function useGroupLocations() {
  const { session } = useAuth();
  const [memberLocations, setMemberLocations] = useState<UserLocation[]>([]);

  useEffect(() => {
    if (!session?.user) return;

    // 1. Fetch initial locations (RLS filters for my groups)
    fetchLocations();

    // 2. Subscribe to changes
    const channel = supabase
      .channel('public:locations')
      .on(
        'postgres_changes',
        {
          event: '*', // INSERT, UPDATE
          schema: 'public',
          table: 'locations',
        },
        (payload) => {
          handleRealtimeUpdate(payload.new as any);
        }
      )
      .subscribe();

    return () => {
      supabase.removeChannel(channel);
    };
  }, [session]);

  async function fetchLocations() {
    const { data, error } = await supabase
      .from('locations')
      .select('user_id, lat, long, timestamp');

    if (error) console.error('Error fetching locations:', error);
    else {
      // De-duplicate by user_id, taking latest?
      // Actually DB schema doesn't enforce 1 loc per user, it's a history log.
      // We should query distinct on user_id or handle it in client.
      // Ideally we should have a view "latest_locations" or just query latest.
      // For now, let's just take the list and process.
      // Better: In real app, 'locations' table might be history log,
      // but let's assume valid 'latest' for now or map it.

      // Let's assume for this MVP, we want the LATEST location for each user.
      // Client-side dedup:
      const locs = processLocations(data);
      setMemberLocations(locs);
    }
  }

  function handleRealtimeUpdate(newLoc: any) {
    setMemberLocations((prev) => {
      return processLocations([...prev, newLoc]);
    });
  }

  function processLocations(rawLocs: any[]) {
    // Map user_id -> latest location
    const map = new Map<string, any>();
    rawLocs.forEach(l => {
      const existing = map.get(l.user_id);
      if (!existing || new Date(l.timestamp) > new Date(existing.timestamp)) {
        map.set(l.user_id, l);
      }
    });
    return Array.from(map.values()) as UserLocation[];
  }

  return { memberLocations };
}
