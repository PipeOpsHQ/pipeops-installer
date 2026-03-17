import React, { createContext, useContext, useEffect, useState, useRef } from 'react';
import { Alert } from 'react-native';
// Use type-only import to avoid runtime native dependency
import type { IRtcEngine } from 'react-native-agora';
import { supabase } from '../lib/supabase';
import { useAuth } from './AuthContext';
import * as Location from 'expo-location';
import Constants from 'expo-constants';

// Environment variable for Agora
const AGORA_APP_ID = process.env.EXPO_PUBLIC_AGORA_APP_ID || '';

// Mock Enums that mimic Agora's structure
const ChannelProfileType = {
  ChannelProfileLiveBroadcasting: 1,
};
const ClientRoleType = {
  ClientRoleBroadcaster: 1,
  ClientRoleAudience: 2,
};

type EmergencyContextType = {
  isEmergencyActive: boolean;
  isListening: boolean;
  triggerEmergency: () => Promise<void>;
  stopEmergency: () => Promise<void>;
  joinEmergencyChannel: (channelId: string) => Promise<void>;
  leaveEmergencyChannel: () => Promise<void>;
};

const EmergencyContext = createContext<EmergencyContextType>({} as any);

export const EmergencyProvider = ({ children }: { children: React.ReactNode }) => {
  const { session } = useAuth();
  const agoraEngine = useRef<IRtcEngine | null>(null);
  const [isEmergencyActive, setIsEmergencyActive] = useState(false); // Broadcaster
  const [isListening, setIsListening] = useState(false); // Audience
  const isExpoGo = Constants.appOwnership === 'expo';

  useEffect(() => {
    if (!isExpoGo) {
      setupAgora();
    }

    // Subscribe to incoming alerts
    const channel = supabase
      .channel('public:alerts')
      .on(
        'postgres_changes',
        {
          event: 'INSERT',
          schema: 'public',
          table: 'alerts',
          filter: 'status=eq.active',
        },
        (payload) => {
          handleIncomingAlert(payload.new);
        }
      )
      .subscribe();

    return () => {
      // safely helper
      if (agoraEngine.current) {
        agoraEngine.current.release();
      }
      supabase.removeChannel(channel);
    };
  }, [session]);

  const handleIncomingAlert = (alert: any) => {
    if (alert.user_id === session?.user.id) return; // Ignore my own alerts here

    Alert.alert(
      'EMERGENCY ALERT',
      'A member of your group needs help!',
      [
        { text: 'Ignore', style: 'cancel' },
        {
          text: 'Listen Live',
          style: 'destructive',
          onPress: () => joinEmergencyChannel(alert.user_id)
        }
      ]
    );
  };

  const setupAgora = async () => {
    if (isExpoGo) return;

    try {
      // Dynamic import to avoid bundling native code in Expo Go
      const { default: createAgoraRtcEngine } = require('react-native-agora');
      agoraEngine.current = createAgoraRtcEngine();
      agoraEngine.current.initialize({ appId: AGORA_APP_ID });

      // Set profile to Live Broadcasting
      agoraEngine.current.setChannelProfile(ChannelProfileType.ChannelProfileLiveBroadcasting);

      agoraEngine.current.addListener('onError', (err: any) => {
        console.error('Agora Error:', err);
      });

      agoraEngine.current.addListener('onJoinChannelSuccess', (connection: any, elapsed: any) => {
        console.log('Joined channel:', connection.channelId);
      });
    } catch (e) {
      console.error('Failed to setup Agora:', e);
    }
  };

  const triggerEmergency = async () => {
    if (!session?.user) return;
    try {
      setIsEmergencyActive(true);

      // 1. Get current location
      const { coords } = await Location.getCurrentPositionAsync({});

      // 2. Create Alert in Supabase
      const { data: alertData, error } = await supabase
        .from('alerts')
        .insert({
          user_id: session.user.id,
          type: 'emergency',
          status: 'active',
          agora_channel_token: null, // If using tokens, generate here
        })
        .select()
        .single();

      if (error) throw error;

      if (isExpoGo) {
        Alert.alert('Simulated Emergency', 'Voice streaming skipped in Expo Go.');
        return;
      }

      // 3. Join Agora Channel (Channel Name = Alert ID or User ID)
      const channelId = session.user.id;

      agoraEngine.current?.setClientRole(ClientRoleType.ClientRoleBroadcaster);
      agoraEngine.current?.enableAudio();
      agoraEngine.current?.joinChannel('', channelId, 0, {}); // Token (empty for test), Channel, UID, Options

      Alert.alert('EMERGENCY ACTIVE', 'Streaming audio to your group.');
    } catch (e: any) {
      Alert.alert('Failed to trigger emergency', e.message);
      setIsEmergencyActive(false);
    }
  };

  const stopEmergency = async () => {
    try {
      if (!isExpoGo) {
        await agoraEngine.current?.leaveChannel();
      }
      setIsEmergencyActive(false);
      setIsListening(false);

      // TODO: Update Alert status to 'resolved' in Supabase
      Alert.alert('Emergency Ended');
    } catch (e) {
      console.error(e);
    }
  };

  const joinEmergencyChannel = async (channelId: string) => {
    try {
      setIsListening(true);
      if (!isExpoGo) {
        agoraEngine.current?.setClientRole(ClientRoleType.ClientRoleAudience);
        agoraEngine.current?.joinChannel('', channelId, 0, {});
      }
      Alert.alert('Connected', 'Listening to emergency audio.');
    } catch (e) {
      console.error(e);
      setIsListening(false);
    }
  };

  const leaveEmergencyChannel = async () => {
    await stopEmergency(); // Same logic for leaving
  };

  return (
    <EmergencyContext.Provider value={{
      isEmergencyActive,
      isListening,
      triggerEmergency,
      stopEmergency,
      joinEmergencyChannel,
      leaveEmergencyChannel
    }}>
      {children}
    </EmergencyContext.Provider>
  );
};

export const useEmergency = () => useContext(EmergencyContext);
