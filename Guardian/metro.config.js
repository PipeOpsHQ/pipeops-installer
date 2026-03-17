// Learn more https://docs.expo.io/guides/customizing-metro
const { getDefaultConfig } = require('expo/metro-config');

/** @type {import('expo/metro-config').MetroConfig} */
const config = getDefaultConfig(__dirname);

// Optionally exclude problematic native modules in development
// This helps with Expo Go compatibility but won't affect production builds

module.exports = config;
