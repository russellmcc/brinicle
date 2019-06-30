/* @flow */
"use strict";
import { NativeModules, NativeEventEmitter } from 'react-native-macos';
import EventEmitter from 'react-native-macos/Libraries/vendor/emitter/EventEmitter';

const KernelRCTManager = NativeModules.KernelRCTManager;
const KernelRCTEvents = new NativeEventEmitter(KernelRCTManager);

class KernelManager extends EventEmitter {
  constructor() {
    super();
    this.parameterInfo = KernelRCTManager.parameterInfo;
    this.grabs = {};
    this.parameters = {};
    this.loaded = false;
    this.onLoadedListeners = [];

    const checkLoaded = () => {
      for (const paramID of Object.keys(this.parameterInfo)) {
        if (!(paramID in this.parameters)) {
          return false;
        }
      }
      return true;
    };
    KernelRCTEvents.addListener('AURCTParamChanged', (event) => {
      const identifier = event.identifier;
      const value = event.value;
      this.parameters[identifier] = value;
      const wasLoaded = this.loaded;
      this.loaded = checkLoaded();
      if (this.loaded && !wasLoaded) {
        for (const f of this.onLoadedListeners) {
          f();
        }
        this.onLoadedListeners = [];
      }
      if (this.loaded) {
        this.emit('changed');
      }
    });
    KernelRCTManager.sendAllParams();
  }

  /**
   * If loaded, calls f on next event loop.  Otherwise, calls f when loaded.
   */
  onload(f: () => void) {
    if (this.loaded) {
      setTimeout(f);
    } else {
      this.onLoadedListeners.push(f);
    }
  }

  setParameter(identifier: string, value: number) {
    if (!this.loaded) {
      return;
    }
    if (this.parameters[identifier] == value) {
      return;
    }
    this.parameters[identifier] = value;
    KernelRCTManager.setParameter(identifier, value);
    this.emit('changed');
  }

  grabParameter(identifier: string) : Promise<number> {
    return KernelRCTManager.grabParameter(identifier).then((g) => {
      this.grabs[g] = identifier;
      return g;
    });
  }

  moveGrabbedParameter(grab: number, value: number) : Promise<void> {
    return KernelRCTManager.moveGrabbedParameter(grab, value).then(() => {
      if (this.grabs[grab]) {
        const identifier = this.grabs[grab];
        if (this.parameters[identifier] == value) {
          return;
        }
        this.parameters[identifier] = value;
        this.emit('changed');
      }
    });
  }

  ungrabParameter(grab: number) : Promise<void> {
    return KernelRCTManager.ungrabParameter(grab).then(() => {
      delete this.grabs[grab];
    });
  }

};

const GlobalKernelManager = new KernelManager();

export default GlobalKernelManager;