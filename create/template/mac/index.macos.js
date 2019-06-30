'use strict';

import React from 'react';
import {
  AppRegistry,
  StyleSheet,
  Text,
  View,
  PanResponder,
} from 'react-native';

import AUReact from 'brinicle';
import AUParamKnob from './AUParamKnob.js';

class AUView extends React.Component {
  state: ?Object;
  constructor() {
    super();
    this.state = null;
    const onchange = () => {
      let state = {};
      for (const paramID of Object.keys(AUReact.parameters)) {
        state[paramID] = AUReact.parameters[paramID];
      }
      this.setState(state);
    };
    AUReact.onload(onchange);
    AUReact.addListener('changed', onchange);
  }
  render() {
    if (this.state) {
      if (this.state['bypass'] == 1.0) {
        return <View style={styles.container}>
        <Text style={styles.title}>
          BYPASS
        </Text>
          </View>
      }
      return <View style={styles.container}>
        <Text style={styles.title}>
        The amazing volume-changing machine
        </Text>
        <Text style={styles.title}>
        Gain: {this.state['gain'].toFixed(2)}
      </Text>
        <View style={{width:200, height:200}}>
        <AUParamKnob
      value={this.state.gain}
      param='gain'
      source={require('./resources/data.json')}
      />
        </View>
      </View>
    } else {
      return <View style={styles.container}>
        <Text style={styles.title}>
          Loading!
        </Text>
      </View>
    }
  }
}

const styles = StyleSheet.create({
  container: {
    paddingTop: 20,
    flex: 1,
    justifyContent: 'center',
    alignItems: 'center',
  },
  title: {
    fontSize: 20,
    fontFamily: "Futura",
    textAlign: 'center',
    margin: 10,
  },
});

// Module name
AppRegistry.registerComponent('AUView', () => AUView);