import React, { createContext, useContext, useEffect, useState } from 'react';
import * as Location from 'expo-location';
import { supabase } from '../lib/supabase';
import { useAuth } from './AuthContext';
import { Alert } from 'react-native';
import AsyncStorage from '@react-native-async-storage/async-storage';
import NetInfo from '@react-native-community/netinfo';

type LocationContextType = {
  location: Location.LocationObject | null;
  errorMsg: string | null;
};

const LocationContext = createContext<LocationContextType>({ location: null, errorMsg: null });

const LOCATION_QUEUE_KEY = 'offline_location_queue';

export const LocationProvider = ({ children }: { children: React.ReactNode }) => {
  const [location, setLocation] = useState<Location.LocationObject | null>(null);
  const [errorMsg, setErrorMsg] = useState<string | null>(null);
  const { session } = useAuth();

  useEffect(() => {
    (async () => {
      let { status } = await Location.requestForegroundPermissionsAsync();
      if (status !== 'granted') {
        setErrorMsg('Permission to access location was denied');
        return;
      }

      const subscription = await Location.watchPositionAsync(
        {
          accuracy: Location.Accuracy.High,
          distanceInterval: 10,
        },
        (newLocation) => {
          setLocation(newLocation);
          handleLocationUpdate(newLocation);
        }
      );

      return () => {
        if (subscription) subscription.remove();
      };
    })();

    // Listen to network state to flush queue
    const unsubscribeNet = NetInfo.addEventListener(state => {
      if (state.isConnected) {
        flushLocationQueue();
      }
    });

    return () => unsubscribeNet();
  }, [session]);

  const handleLocationUpdate = async (loc: Location.LocationObject) => {
    if (!session?.user) return;

    const payload = {
      user_id: session.user.id,
      lat: loc.coords.latitude,
      long: loc.coords.longitude,
      speed: loc.coords.speed,
      heading: loc.coords.heading,
      battery_level: -1,
      timestamp: new Date(loc.timestamp).toISOString(),
    };

    const state = await NetInfo.fetch();
    if (state.isConnected) {
      const { error } = await supabase.from('locations').upsert(payload);
      if (error) {
        console.error('Realtime upload failed, queuing', error);
        queueLocation(payload);
      }
    } else {
      queueLocation(payload);
    }
  };

  const queueLocation = async (payload: any) => {
    try {
      const queue = JSON.parse((await AsyncStorage.getItem(LOCATION_QUEUE_KEY)) || '[]');
      queue.push(payload);
      await AsyncStorage.setItem(LOCATION_QUEUE_KEY, JSON.stringify(queue));
    } catch (e) {
      console.error('Failed to queue location', e);
    }
  };

  const flushLocationQueue = async () => {
    try {
      const queueStr = await AsyncStorage.getItem(LOCATION_QUEUE_KEY);
      if (!queueStr) return;

      const queue = JSON.parse(queueStr);
      if (queue.length === 0) return;

      console.log(`Flushing ${queue.length} locations...`);

      const { error } = await supabase.from('locations').upsert(queue);

      if (!error) {
        await AsyncStorage.removeItem(LOCATION_QUEUE_KEY);
        console.log('Queue flushed');
      } else {
        console.error('Failed to flush queue', error);
      }
    } catch (e) {
      console.error('Error flushing queue', e);
    }
  };

  return (
    <LocationContext.Provider value={{ location, errorMsg }}>
      {children}
    </LocationContext.Provider>
  );
};

export const useLocation = () => useContext(LocationContext);
