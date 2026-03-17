import React, { useEffect, useState } from 'react';
import { View, Text, TextInput, TouchableOpacity, FlatList, StyleSheet, Alert, SafeAreaView, ActivityIndicator } from 'react-native';
import { supabase } from '../lib/supabase';
import { useAuth } from '../context/AuthContext';
import { useNavigation } from '@react-navigation/native';
import { Theme } from '../constants/Colors';
import { BlurView } from 'expo-blur';
import { Ionicons } from '@expo/vector-icons';

type Group = {
  id: string;
  name: string;
  join_code: string;
};

export default function GroupScreen() {
  const { session } = useAuth();
  const [groups, setGroups] = useState<Group[]>([]);
  const [newGroupName, setNewGroupName] = useState('');
  const [joinCode, setJoinCode] = useState('');
  const [loading, setLoading] = useState(false);
  const navigation = useNavigation();

  useEffect(() => {
    fetchGroups();
  }, []);

  async function fetchGroups() {
    if (!session?.user) return;
    setLoading(true);
    const { data, error } = await supabase
      .from('group_members')
      .select('group:groups(id, name, join_code)')
      .eq('user_id', session.user.id);

    if (error) Alert.alert('Network Error', error.message);
    else if (data) {
      const loadedGroups = data.map((item: any) => item.group).filter(Boolean);
      setGroups(loadedGroups);
    }
    setLoading(false);
  }

  async function createGroup() {
    if (!newGroupName.trim()) return;
    if (!session?.user) return;
    setLoading(true);

    const code = Math.random().toString(36).substring(2, 8).toUpperCase();
    const { data: group, error: groupError } = await supabase
      .from('groups')
      .insert({ name: newGroupName, join_code: code, created_by: session.user.id })
      .select().single();

    if (groupError) {
      Alert.alert('Protocol Failure', groupError.message);
      setLoading(false);
      return;
    }

    const { error: memberError } = await supabase
      .from('group_members')
      .insert({ group_id: group.id, user_id: session.user.id, role: 'admin' });

    if (memberError) Alert.alert('Member Init Failed', memberError.message);
    else {
      setNewGroupName('');
      fetchGroups();
    }
  }

  async function joinGroup() {
    if (!joinCode.trim()) return;
    if (!session?.user) return;
    setLoading(true);

    const { data: group, error: findError } = await supabase
      .from('groups').select('id').eq('join_code', joinCode.toUpperCase()).single();

    if (findError || !group) {
      Alert.alert('Access Denied', 'Invalid Join Code');
      setLoading(false);
      return;
    }

    const { error: joinError } = await supabase
      .from('group_members')
      .insert({ group_id: group.id, user_id: session.user.id, role: 'member' });

    if (joinError) {
      if (joinError.code === '23505') Alert.alert('Status: Active', 'You are already in this group.');
      else Alert.alert('Handshake Failed', joinError.message);
    } else {
      setJoinCode('');
      fetchGroups();
    }
    setLoading(false);
  }

  return (
    <SafeAreaView style={styles.container}>
      <View style={styles.header}>
        <TouchableOpacity onPress={() => navigation.goBack()} style={styles.backButton}>
          <Ionicons name="chevron-back" size={24} color={Theme.text} />
        </TouchableOpacity>
        <Text style={styles.headerTitle}>Network Protocols</Text>
        <View style={{ width: 44 }} />
      </View>

      <View style={styles.content}>
        <Text style={styles.sectionLabel}>ACTIVE GROUPS</Text>
        <FlatList
          data={groups}
          keyExtractor={(item) => item.id}
          style={styles.list}
          renderItem={({ item }) => (
            <BlurView intensity={20} tint="dark" style={styles.groupCard}>
              <View>
                <Text style={styles.groupName}>{item.name}</Text>
                <Text style={styles.groupCodeLabel}>KEY: <Text style={styles.groupCode}>{item.join_code}</Text></Text>
              </View>
              <TouchableOpacity style={styles.inviteButton}>
                <Ionicons name="share-outline" size={20} color={Theme.primary} />
              </TouchableOpacity>
            </BlurView>
          )}
          ListEmptyComponent={
            loading ? <ActivityIndicator color={Theme.primary} /> :
              <Text style={styles.emptyText}>- NO ACTIVE PROTOCOLS FOUND -</Text>
          }
        />

        <BlurView intensity={30} tint="dark" style={styles.actionSection}>
          <Text style={styles.actionLabel}>INITIALIZE NEW GROUP</Text>
          <View style={styles.inputRow}>
            <TextInput
              style={styles.input}
              placeholder="Designation (e.g. Unit 01)"
              placeholderTextColor={Theme.textTertiary}
              value={newGroupName}
              onChangeText={setNewGroupName}
            />
            <TouchableOpacity style={styles.actionBtn} onPress={createGroup}>
              <Ionicons name="add" size={24} color="#fff" />
            </TouchableOpacity>
          </View>

          <View style={styles.divider} />

          <Text style={styles.actionLabel}>JOIN EXISTING NETWORK</Text>
          <View style={styles.inputRow}>
            <TextInput
              style={[styles.input, { letterSpacing: 4, textTransform: 'uppercase' }]}
              placeholder="ENTER KEY"
              placeholderTextColor={Theme.textTertiary}
              value={joinCode}
              onChangeText={setJoinCode}
              autoCapitalize="characters"
            />
            <TouchableOpacity style={[styles.actionBtn, { backgroundColor: Theme.secondary }]} onPress={joinGroup}>
              <Ionicons name="arrow-forward" size={24} color="#fff" />
            </TouchableOpacity>
          </View>
        </BlurView>
      </View>
    </SafeAreaView>
  );
}

const styles = StyleSheet.create({
  container: {
    flex: 1,
    backgroundColor: Theme.background,
  },
  header: {
    flexDirection: 'row',
    alignItems: 'center',
    justifyContent: 'space-between',
    paddingHorizontal: 20,
    paddingVertical: 15,
  },
  backButton: {
    width: 44,
    height: 44,
    borderRadius: 22,
    alignItems: 'center',
    justifyContent: 'center',
    backgroundColor: 'rgba(255, 255, 255, 0.05)',
  },
  headerTitle: {
    fontSize: 16,
    fontWeight: '800',
    color: '#fff',
    letterSpacing: 2,
  },
  content: {
    flex: 1,
    padding: 20,
  },
  sectionLabel: {
    fontSize: 10,
    fontWeight: '900',
    color: Theme.textSecondary,
    letterSpacing: 3,
    marginBottom: 15,
  },
  list: {
    flex: 1,
    marginBottom: 20,
  },
  groupCard: {
    flexDirection: 'row',
    justifyContent: 'space-between',
    alignItems: 'center',
    padding: 20,
    borderRadius: 20,
    marginBottom: 12,
    borderWidth: 1,
    borderColor: 'rgba(255, 255, 255, 0.05)',
    overflow: 'hidden',
  },
  groupName: {
    fontSize: 17,
    fontWeight: '700',
    color: '#fff',
    marginBottom: 4,
  },
  groupCodeLabel: {
    fontSize: 11,
    color: Theme.textSecondary,
    fontWeight: '600',
  },
  groupCode: {
    color: Theme.accent,
    fontWeight: '800',
    letterSpacing: 1,
  },
  inviteButton: {
    width: 40,
    height: 40,
    borderRadius: 20,
    backgroundColor: 'rgba(10, 132, 255, 0.1)',
    alignItems: 'center',
    justifyContent: 'center',
  },
  emptyText: {
    textAlign: 'center',
    color: Theme.textTertiary,
    fontSize: 10,
    fontWeight: '700',
    marginTop: 40,
    letterSpacing: 2,
  },
  actionSection: {
    padding: 24,
    borderRadius: 28,
    borderWidth: 1,
    borderColor: 'rgba(255, 255, 255, 0.1)',
    overflow: 'hidden',
    backgroundColor: 'rgba(255, 255, 255, 0.02)',
  },
  actionLabel: {
    fontSize: 9,
    fontWeight: '900',
    color: Theme.textSecondary,
    letterSpacing: 2.5,
    marginBottom: 12,
  },
  inputRow: {
    flexDirection: 'row',
    gap: 12,
    marginBottom: 12,
  },
  input: {
    flex: 1,
    height: 50,
    backgroundColor: 'rgba(255, 255, 255, 0.03)',
    borderRadius: 12,
    paddingHorizontal: 16,
    color: '#fff',
    fontSize: 14,
    fontWeight: '600',
    borderWidth: 1,
    borderColor: 'rgba(255, 255, 255, 0.05)',
  },
  actionBtn: {
    width: 50,
    height: 50,
    borderRadius: 15,
    backgroundColor: Theme.primary,
    alignItems: 'center',
    justifyContent: 'center',
    shadowColor: Theme.primary,
    shadowOffset: { width: 0, height: 4 },
    shadowOpacity: 0.3,
    shadowRadius: 6,
  },
  divider: {
    height: 1,
    backgroundColor: 'rgba(255, 255, 255, 0.05)',
    marginVertical: 12,
  }
});
