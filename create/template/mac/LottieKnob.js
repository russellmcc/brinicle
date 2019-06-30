import React from 'react';
import {
  PanResponder,
} from 'react-native';
import LottieView from 'lottie-react-native';

export default class LottieKnob extends React.Component {
  constructor(props) {
    super(props);
    this.gestureData = null;
    this.state = {
      overrideValue: null
    };
    this.panResponder = PanResponder.create({
      onStartShouldSetPanResponder: (evt, gestureState) => true,
      onStartShouldSetPanResponderCapture: (evt, gestureState) => true,
      onMoveShouldSetPanResponder: (evt, gestureState) => true,
      onMoveShouldSetPanResponderCapture: (evt, gestureState) => true,
      onShouldBlockNativeResponder: () => true,
      onPanResponderGrant: (evt, gestureState) => {
        if (this.gestureData != null) {
          console.error("Starting a gesture while gesture already active");
        }
        this.gestureData = {
          initialValue: this.props.value,
          workingValue: this.props.value,
          prevDPixels: 0,
          clientData: this.props.startGesture ? this.props.startGesture() : null,
        };
      },
      onPanResponderMove: (evt, gestureState) => {
        if (this.gestureData == null) {
          console.error("moved without having started a gesture!");
          return;
        }
        if (this.gestureData.clientData) {
          const valuePerPixel = (this.props.maximumValue - this.props.minimumValue) / this.props.throw;
          const dPixels = (-gestureState.dy);
          const ddPixels = dPixels - this.gestureData.prevDPixels;
          this.gestureData.prevDPixels = dPixels;

          let newWorkingValue = this.gestureData.workingValue + ddPixels * valuePerPixel;
          if (newWorkingValue < this.props.minimumValue) {
            newWorkingValue = this.props.minimumValue;
          } else if (newWorkingValue > this.props.maximumValue) {
            newWorkingValue = this.props.maximumValue;
          }
          if (newWorkingValue != this.gestureData.workingValue) {
            this.gestureData.workingValue = newWorkingValue;
            this.setState({
              overrideValue: this.gestureData.workingValue
            });
            if (this.gestureData.clientData) {
              this.gestureData.clientData.setNewValue(newWorkingValue);
            }
          }
        }
      },
      onPanResponderTerminationRequest: () => true,
      onPanResponderTerminate: () => {
        this.panResponder.onPanResponderRelease();
      },
      onPanResponderRelease: () => {
        if (this.gestureData == null) {
          console.error("terminated without having started a gesture!");
          return;
        }
        if (this.gestureData.clientData) {
          this.gestureData.clientData.end();
        }
        this.setState({
          overrideValue: null
        });
        this.gestureData = null;
      }
    });
  }

  static defaultProps = {
    value: 0.5,
    minimumValue: 0.0,
    maximumValue: 1.0,
    throw: 200,
    optimistic: false
  };

  render() {
    const optimisticValue = this.state.overrideValue ? this.state.overrideValue : this.props.value;
    const activeValue = this.props.optimistic ? optimisticValue : this.props.value;
    const progressForValue = (activeValue - this.props.minimumValue) / (this.props.maximumValue - this.props.minimumValue);
    return <LottieView
      {...this.panResponder.panHandlers}
    source={this.props.source}
    progress={progressForValue}
      />;
  }
};