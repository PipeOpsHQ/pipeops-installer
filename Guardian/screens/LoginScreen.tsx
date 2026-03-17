import React, { useState } from 'react';
import { View, TextInput, TouchableOpacity, StyleSheet, Alert, Text, Dimensions, ActivityIndicator } from 'react-native';
import { supabase } from '../lib/supabase';
import { Theme } from '../constants/Colors';
import { BlurView } from 'expo-blur';
import { Ionicons } from '@expo/vector-icons';

const { width } = Dimensions.get('window');

export default function LoginScreen() {
  const [email, setEmail] = useState('');
  const [password, setPassword] = useState('');
  const [loading, setLoading] = useState(false);

  async function signIn() {
    setLoading(true);
    const { error } = await supabase.auth.signInWithPassword({ email, password });
    if (error) Alert.alert('Authentication Failed', error.message);
    setLoading(false);
  }

  async function signUp() {
    setLoading(true);
    const { error } = await supabase.auth.signUp({ email, password });
    if (error) Alert.alert('Error', error.message);
    else Alert.alert('Verification Sent', 'Check your email to verify your account.');
    setLoading(false);
  }

  return (
    <View style={styles.container}>
      <View style={styles.backgroundAccent}>
        <View style={styles.glow} />
      </View>

      <View style={styles.header}>
        <View style={styles.logoContainer}>
          <Ionicons name="shield-checkmark" size={40} color={Theme.primary} />
        </View>
        <Text style={styles.title}>GUARDIAN</Text>
        <Text style={styles.subtitle}>Enabling high-performance safety protocols.</Text>
      </View>

      <BlurView intensity={40} tint="dark" style={styles.authCard}>
        <View style={styles.inputContainer}>
          <Ionicons name="mail-outline" size={20} color={Theme.textSecondary} style={styles.inputIcon} />
          <TextInput
            style={styles.input}
            placeholder="Network ID (Email)"
            placeholderTextColor={Theme.textTertiary}
            value={email}
            onChangeText={setEmail}
            autoCapitalize="none"
            keyboardType="email-address"
          />
        </View>

        <View style={styles.inputContainer}>
          <Ionicons name="lock-closed-outline" size={20} color={Theme.textSecondary} style={styles.inputIcon} />
          <TextInput
            style={styles.input}
            placeholder="Security Key (Password)"
            placeholderTextColor={Theme.textTertiary}
            value={password}
            onChangeText={setPassword}
            secureTextEntry
          />
        </View>

        <TouchableOpacity
          style={[styles.primaryButton, loading && styles.buttonDisabled]}
          onPress={signIn}
          disabled={loading}
        >
          {loading ? (
            <ActivityIndicator color="#fff" />
          ) : (
            <Text style={styles.primaryButtonText}>INITIATE SESSION</Text>
          )}
        </TouchableOpacity>

        <TouchableOpacity
          style={styles.secondaryButton}
          onPress={signUp}
          disabled={loading}
        >
          <Text style={styles.secondaryButtonText}>Create New Protocol</Text>
        </TouchableOpacity>
      </BlurView>

      <Text style={styles.footer}>v1.0.4-LITE // ENCRYPTED END-TO-END</Text>
    </View>
  );
}

const styles = StyleSheet.create({
  container: {
    flex: 1,
    backgroundColor: Theme.background,
    justifyContent: 'center',
    padding: 30,
  },
  backgroundAccent: {
    ...StyleSheet.absoluteFillObject,
    alignItems: 'center',
    justifyContent: 'center',
    overflow: 'hidden',
    zIndex: -1,
  },
  glow: {
    width: 300,
    height: 300,
    borderRadius: 150,
    backgroundColor: Theme.primary,
    opacity: 0.05,
    filter: 'blur(100px)',
  },
  header: {
    alignItems: 'center',
    marginBottom: 50,
  },
  logoContainer: {
    marginBottom: 20,
    shadowColor: Theme.primary,
    shadowOffset: { width: 0, height: 0 },
    shadowOpacity: 0.5,
    shadowRadius: 15,
  },
  title: {
    fontSize: 28,
    fontWeight: '900',
    color: '#fff',
    letterSpacing: 8,
    textAlign: 'center',
    marginBottom: 8,
  },
  subtitle: {
    fontSize: 12,
    color: Theme.textSecondary,
    fontWeight: '500',
    letterSpacing: 0.5,
    textAlign: 'center',
  },
  authCard: {
    borderRadius: 24,
    padding: 24,
    borderWidth: 1,
    borderColor: 'rgba(255, 255, 255, 0.1)',
    overflow: 'hidden',
  },
  inputContainer: {
    flexDirection: 'row',
    alignItems: 'center',
    backgroundColor: 'rgba(255, 255, 255, 0.03)',
    borderRadius: 14,
    marginBottom: 16,
    borderWidth: 1,
    borderColor: 'rgba(255, 255, 255, 0.05)',
  },
  inputIcon: {
    paddingLeft: 16,
  },
  input: {
    flex: 1,
    height: 54,
    paddingHorizontal: 12,
    color: '#fff',
    fontSize: 15,
    fontWeight: '500',
  },
  primaryButton: {
    backgroundColor: Theme.primary,
    height: 54,
    borderRadius: 14,
    alignItems: 'center',
    justifyContent: 'center',
    marginTop: 10,
    shadowColor: Theme.primary,
    shadowOffset: { width: 0, height: 4 },
    shadowOpacity: 0.3,
    shadowRadius: 8,
    elevation: 4,
  },
  buttonDisabled: {
    opacity: 0.6,
  },
  primaryButtonText: {
    color: '#fff',
    fontWeight: '800',
    fontSize: 14,
    letterSpacing: 2,
  },
  secondaryButton: {
    height: 54,
    borderRadius: 14,
    alignItems: 'center',
    justifyContent: 'center',
    marginTop: 8,
  },
  secondaryButtonText: {
    color: Theme.textSecondary,
    fontWeight: '600',
    fontSize: 14,
  },
  footer: {
    position: 'absolute',
    bottom: 40,
    left: 0,
    right: 0,
    textAlign: 'center',
    color: Theme.textTertiary,
    fontSize: 9,
    fontWeight: '700',
    letterSpacing: 1.5,
  }
});
