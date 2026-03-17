import React from 'react';
import { NavigationContainer, DarkTheme as NavigationDarkTheme } from '@react-navigation/native';
import { createNativeStackNavigator } from '@react-navigation/native-stack';
import { AuthProvider, useAuth } from './context/AuthContext';
import LoginScreen from './screens/LoginScreen';
import HomeScreen from './screens/HomeScreen';
import GroupScreen from './screens/GroupScreen';
import { LocationProvider } from './context/LocationContext';
import { EmergencyProvider } from './context/EmergencyContext';
import { Theme } from './constants/Colors';

const Stack = createNativeStackNavigator();

function Navigation() {
  const { session, loading } = useAuth();

  if (loading) {
    return null; // Or a splash screen
  }

  const CustomDarkTheme = {
    ...NavigationDarkTheme,
    colors: {
      ...NavigationDarkTheme.colors,
      primary: Theme.primary,
      background: Theme.background,
      card: Theme.surface,
      text: Theme.text,
      border: Theme.border,
      notification: Theme.error,
    },
  };

  return (
    <NavigationContainer theme={CustomDarkTheme}>
      <Stack.Navigator screenOptions={{
        headerStyle: { backgroundColor: Theme.surface },
        headerTintColor: Theme.text,
        contentStyle: { backgroundColor: Theme.background },
      }}>
        {session ? (
          <>
            <Stack.Screen name="Home" component={HomeScreen} options={{ headerShown: false }} />
            <Stack.Screen name="Groups" component={GroupScreen} />
          </>
        ) : (
          <Stack.Screen name="Login" component={LoginScreen} options={{ headerShown: false }} />
        )}
      </Stack.Navigator>
    </NavigationContainer>
  );
}

export default function App() {
  return (
    <AuthProvider>
      <LocationProvider>
        <EmergencyProvider>
          <Navigation />
        </EmergencyProvider>
      </LocationProvider>
    </AuthProvider>
  );
}
