import React, { useEffect, useState, useRef } from 'react';
import { View, Text, StyleSheet, Alert, TouchableOpacity, SafeAreaView, Dimensions, Animated, Pressable } from 'react-native';
import { supabase } from '../lib/supabase';
import { useLocation } from '../context/LocationContext';
import { useNavigation } from '@react-navigation/native';
import { useGroupLocations } from '../hooks/useGroupLocations';
import { useEmergency } from '../context/EmergencyContext';
import MapWrapper from '../components/MapWrapper';
import { Ionicons } from '@expo/vector-icons';
import { Theme } from '../constants/Colors';
import Constants from 'expo-constants';
import { BlurView } from 'expo-blur';

const { width } = Dimensions.get('window');

export default function HomeScreen() {
  const { location, errorMsg } = useLocation();
  const { memberLocations } = useGroupLocations();
  const { isEmergencyActive, triggerEmergency, stopEmergency } = useEmergency();
  const navigation = useNavigation<any>();
  const [centerKey, setCenterKey] = useState(0);

  // Animated SOS trigger progress
  const sosProgress = useRef(new Animated.Value(0)).current;
  const [isPressing, setIsPressing] = useState(false);

  useEffect(() => {
    if (errorMsg) {
      Alert.alert('Location Error', errorMsg);
    }
  }, [errorMsg]);

  const handleRecenter = () => {
    setCenterKey(prev => prev + 1);
  };

  const handlePressIn = () => {
    setIsPressing(true);
    Animated.timing(sosProgress, {
      toValue: 1,
      duration: 3000,
      useNativeDriver: false,
    }).start(({ finished }) => {
      if (finished) {
        if (isEmergencyActive) {
          stopEmergency();
        } else {
          triggerEmergency();
        }
        resetProgress();
      }
    });
  };

  const handlePressOut = () => {
    setIsPressing(false);
    resetProgress();
  };

  const resetProgress = () => {
    sosProgress.stopAnimation();
    Animated.timing(sosProgress, {
      toValue: 0,
      duration: 300,
      useNativeDriver: false,
    }).start();
  };

  const progressWidth = sosProgress.interpolate({
    inputRange: [0, 1],
    outputRange: ['0%', '100%'],
  });

  return (
    <View style={styles.container}>
      <MapWrapper location={location} memberLocations={memberLocations} centerKey={centerKey} />

      {/* Premium Apple-Style Status Pill (Stealth SOS Host) */}
      <SafeAreaView style={styles.topBar}>
        <BlurView intensity={80} tint="dark" style={styles.glassPill}>
          <Pressable
            onPressIn={handlePressIn}
            onPressOut={handlePressOut}
            style={styles.pillContent}
          >
            {/* Background Progress Bar (Stealthy) */}
            <Animated.View style={[
              styles.progressBar,
              { width: progressWidth, backgroundColor: isEmergencyActive ? Theme.textTertiary : Theme.error + '40' }
            ]} />

            <View style={styles.statusRow}>
              <View style={[styles.pulseDot, { backgroundColor: isEmergencyActive ? Theme.error : Theme.success }]} />
              <Text style={styles.systemStatus}>
                {isEmergencyActive ? "CRITICAL: BROADCASTING" : "SYSTEM: ACTIVE"}
              </Text>
              <Text style={styles.uptime}>UP: 00:42:12</Text>
            </View>

            <View style={styles.nerdyRow}>
              <View style={styles.metricBlock}>
                <Text style={styles.metricLabel}>ACC</Text>
                <Text style={styles.metricValue}>5.2m</Text>
              </View>
              <View style={styles.separator} />
              <View style={styles.metricBlock}>
                <Text style={styles.metricLabel}>LAT</Text>
                <Text style={styles.metricValue}>24ms</Text>
              </View>
              <View style={styles.separator} />
              <View style={styles.metricBlock}>
                <Text style={styles.metricLabel}>SYN</Text>
                <Text style={[styles.metricValue, { color: Theme.success }]}>IDLE</Text>
              </View>
              <View style={styles.separator} />
              <View style={styles.metricBlock}>
                <Text style={styles.metricLabel}>NET</Text>
                <Text style={styles.metricValue}>LTE</Text>
              </View>
            </View>
          </Pressable>
        </BlurView>
      </SafeAreaView>

      {/* Floating Control Bar - Glassmorphism */}
      <View style={styles.sideControls}>
        <BlurView intensity={70} tint="dark" style={styles.glassControlBar}>
          <TouchableOpacity style={styles.iconButton} onPress={handleRecenter}>
            <Ionicons name="location" size={22} color={Theme.text} />
          </TouchableOpacity>

          <View style={styles.controlDivider} />

          <TouchableOpacity style={styles.iconButton} onPress={() => navigation.navigate('Groups')}>
            <Ionicons name="people" size={22} color={Theme.text} />
          </TouchableOpacity>

          <View style={styles.controlDivider} />

          <TouchableOpacity style={styles.iconButton} onPress={() => supabase.auth.signOut()}>
            <Ionicons name="power" size={22} color={Theme.error} />
          </TouchableOpacity>
        </BlurView>
      </View>

      {/* Location Breadcrumb Overlay */}
      {location && (
        <View style={styles.breadcrumbContainer}>
          <BlurView intensity={50} tint="dark" style={styles.glassBreadcrumb}>
            <Text style={styles.coords}>
              GEO_ID: {location.coords.latitude.toFixed(6)}, {location.coords.longitude.toFixed(6)}
            </Text>
          </BlurView>
        </View>
      )}
    </View>
  );
}

const styles = StyleSheet.create({
  container: {
    flex: 1,
    backgroundColor: Theme.background,
  },
  topBar: {
    position: 'absolute',
    top: 40,
    left: 0,
    right: 0,
    alignItems: 'center',
    zIndex: 10,
  },
  glassPill: {
    borderRadius: 28,
    overflow: 'hidden',
    borderWidth: 1,
    borderColor: 'rgba(255, 255, 255, 0.12)',
    shadowColor: '#000',
    shadowOffset: { width: 0, height: 10 },
    shadowOpacity: 0.6,
    shadowRadius: 12,
  },
  pillContent: {
    paddingVertical: 14,
    paddingHorizontal: 28,
    alignItems: 'center',
    width: width * 0.85,
    position: 'relative',
    overflow: 'hidden',
  },
  progressBar: {
    position: 'absolute',
    left: 0,
    top: 0,
    bottom: 0,
    zIndex: -1,
  },
  statusRow: {
    flexDirection: 'row',
    alignItems: 'center',
    justifyContent: 'space-between',
    width: '100%',
    marginBottom: 8,
  },
  pulseDot: {
    width: 6,
    height: 6,
    borderRadius: 3,
  },
  systemStatus: {
    color: '#fff',
    fontSize: 10,
    fontWeight: '900',
    letterSpacing: 2.5,
    textTransform: 'uppercase',
    flex: 1,
    marginLeft: 10,
  },
  uptime: {
    color: Theme.textTertiary,
    fontSize: 9,
    fontFamily: 'Courier',
    fontWeight: '700',
  },
  nerdyRow: {
    flexDirection: 'row',
    alignItems: 'center',
    justifyContent: 'space-between',
    width: '100%',
    paddingHorizontal: 4,
  },
  metricBlock: {
    alignItems: 'center',
  },
  metricLabel: {
    color: Theme.textTertiary,
    fontSize: 8,
    fontWeight: '800',
    marginBottom: 2,
  },
  metricValue: {
    color: Theme.textSecondary,
    fontSize: 10,
    fontWeight: '700',
    fontFamily: 'monospace',
  },
  separator: {
    width: 1,
    height: 12,
    backgroundColor: 'rgba(255, 255, 255, 0.08)',
  },
  sideControls: {
    position: 'absolute',
    right: 20,
    top: '35%',
    zIndex: 10,
  },
  glassControlBar: {
    borderRadius: 24,
    overflow: 'hidden',
    borderWidth: 1,
    borderColor: 'rgba(255, 255, 255, 0.15)',
    padding: 8,
    alignItems: 'center',
    gap: 16,
  },
  iconButton: {
    width: 44,
    height: 44,
    borderRadius: 22,
    alignItems: 'center',
    justifyContent: 'center',
  },
  controlDivider: {
    width: 20,
    height: 1,
    backgroundColor: 'rgba(255, 255, 255, 0.1)',
  },
  breadcrumbContainer: {
    position: 'absolute',
    bottom: 40,
    left: 20,
    zIndex: 10,
  },
  glassBreadcrumb: {
    borderRadius: 14,
    overflow: 'hidden',
    paddingVertical: 8,
    paddingHorizontal: 16,
    borderWidth: 1,
    borderColor: 'rgba(255, 255, 255, 0.1)',
  },
  coords: {
    color: Theme.textSecondary,
    fontSize: 9,
    fontWeight: '700',
    letterSpacing: 1,
    fontFamily: 'monospace',
  }
});
